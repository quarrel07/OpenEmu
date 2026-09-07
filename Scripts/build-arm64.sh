#!/bin/bash
# Build OpenEmu natively for arm64 with universal (arm64 + x86_64) cores for
# the systems this fork maintains: Mupen64Plus (N64), Mednafen (Virtual Boy,
# PlayStation, and others), DeSmuME (Nintendo DS).
#
# Usage:  Scripts/build-arm64.sh [--install-cores] [--sign-downloaded-cores]
#
#   --install-cores          copy the universal cores into
#                            ~/Library/Application Support/OpenEmu/Cores,
#                            moving any existing copies to a dated backup
#   --sign-downloaded-cores  ad-hoc sign the cores OpenEmu downloaded itself;
#                            they ship unsigned, which native arm64 refuses
#
# Environment overrides:
#   APP_ARCHS   architectures for the app itself (default: arm64;
#               "arm64 x86_64" builds a universal app)
#   SIGN        codesign identity (default: "-", ad-hoc)
#
# Output: build/dist/OpenEmu.app and build/dist/Cores/*.oecoreplugin
#
# Notes that cost real time to learn:
#   * Cores must be built Release (Mednafen refuses Debug) and into the same
#     derived-data folder as OpenEmuBase, which they link from BUILT_PRODUCTS_DIR.
#   * Warnings-as-errors must be off: OpenEmu-SDK has an enum comparison that
#     Xcode 26 treats as an error.
#   * The app loads cores from Application Support before its own bundle and
#     the first core registered by name wins, so installed cores must carry an
#     arm64 slice for the native app and an x86_64 slice for the Intel release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP_ARCHS="${APP_ARCHS:-arm64}"
SIGN="${SIGN:--}"
DD_ARM="$ROOT/build/dd-arm64"
DD_X86="$ROOT/build/dd-x86_64"
DIST="$ROOT/build/dist"
LOGS="$ROOT/build/logs"
CORES=(Mupen64Plus Mednafen DeSmuME)
INSTALL_CORES=no
SIGN_DOWNLOADED=no
for arg in "$@"; do
  case "$arg" in
    --install-cores) INSTALL_CORES=yes ;;
    --sign-downloaded-cores) SIGN_DOWNLOADED=yes ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

COMMON=(CODE_SIGN_IDENTITY="$SIGN" GCC_TREAT_WARNINGS_AS_ERRORS=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=NO ONLY_ACTIVE_ARCH=NO)
mkdir -p "$LOGS" "$DIST/Cores"

step() { printf '\n==> %s\n' "$*"; }

build() { # build <log-name> <xcodebuild args...>
  local log="$LOGS/$1.log"; shift
  if ! xcodebuild "$@" "${COMMON[@]}" build > "$log" 2>&1; then
    echo "BUILD FAILED, see $log"; grep -E 'error:' "$log" | sort -u | head -20; exit 1
  fi
}

core_project_args() { # prints -project/-scheme for a core
  case "$1" in
    DeSmuME) printf '%s\n' -project "DeSmuME/src/cocoa/DeSmuME (Latest).xcodeproj" -scheme "DeSmuME (OpenEmu Plug-in)" ;;
    *)       printf '%s\n' -project "$1/$1.xcodeproj" -scheme "$1" ;;
  esac
}

is_macho() { [ -f "$1" ] && [ ! -L "$1" ] && file -b "$1" | grep -q 'Mach-O'; }

step "Submodules"
git submodule update --init --recursive OpenEmu-SDK OpenEmuKit OpenEmu-Shaders "${CORES[@]}"

step "App ($APP_ARCHS, Release)"
build app -workspace OpenEmu.xcworkspace -scheme OpenEmu -configuration Release ARCHS="$APP_ARCHS" -derivedDataPath "$DD_ARM"

step "OpenEmuBase for x86_64 (cores link against it)"
build openemubase-x86_64 -workspace OpenEmu.xcworkspace -scheme OpenEmuBase -configuration Release -arch x86_64 -derivedDataPath "$DD_X86"

for core in "${CORES[@]}"; do
  args=(); while IFS= read -r line; do args+=("$line"); done < <(core_project_args "$core")
  step "$core arm64"
  build "$core-arm64" "${args[@]}" -configuration Release -arch arm64 -derivedDataPath "$DD_ARM"
  step "$core x86_64"
  build "$core-x86_64" "${args[@]}" -configuration Release -arch x86_64 -derivedDataPath "$DD_X86"
done

step "Merge cores into universal bundles"
for core in "${CORES[@]}"; do
  a="$DD_ARM/Build/Products/Release/$core.oecoreplugin"
  x="$DD_X86/Build/Products/Release/$core.oecoreplugin"
  u="$DIST/Cores/$core.oecoreplugin"
  rm -rf "$u"; ditto "$a" "$u"
  n=0
  while IFS= read -r -d '' f; do
    rel="${f#"$u"/}"
    if is_macho "$f"; then
      [ -f "$x/$rel" ] || { echo "missing x86_64 counterpart: $rel"; exit 1; }
      lipo -create "$a/$rel" "$x/$rel" -output "$f"; n=$((n+1))
    fi
  done < <(find "$u" -type f -print0)
  codesign --force --deep -s "$SIGN" "$u" 2>/dev/null
  printf '  %-12s %s Mach-O files merged: %s\n' "$core" "$n" "$(lipo -archs "$u/Contents/MacOS/$core")"
done

step "Stage app"
rm -rf "$DIST/OpenEmu.app"; ditto "$DD_ARM/Build/Products/Release/OpenEmu.app" "$DIST/OpenEmu.app"
codesign --force --deep -s "$SIGN" "$DIST/OpenEmu.app" 2>/dev/null
printf '  OpenEmu.app: %s\n' "$(lipo -archs "$DIST/OpenEmu.app/Contents/MacOS/OpenEmu")"

APPCORES="$HOME/Library/Application Support/OpenEmu/Cores"
if [ "$INSTALL_CORES" = yes ]; then
  step "Install universal cores"
  if pgrep -x OpenEmu >/dev/null; then echo "OpenEmu is running; quit it first."; exit 1; fi
  bak="$(dirname "$APPCORES")/Cores-backup-$(date +%Y%m%d-%H%M%S)"
  for core in "${CORES[@]}"; do
    if [ -d "$APPCORES/$core.oecoreplugin" ]; then mkdir -p "$bak"; mv "$APPCORES/$core.oecoreplugin" "$bak/"; fi
    ditto "$DIST/Cores/$core.oecoreplugin" "$APPCORES/$core.oecoreplugin"
    printf '  installed %s\n' "$core"
  done
  [ -d "$bak" ] && echo "  previous cores moved to: $bak"
fi

if [ "$SIGN_DOWNLOADED" = yes ]; then
  step "Ad-hoc sign downloaded cores"
  for c in "$APPCORES"/*.oecoreplugin; do
    if ! codesign -dv "$c" >/dev/null 2>&1; then codesign --force --deep -s - "$c" 2>/dev/null; printf '  signed %s\n' "$(basename "$c")"; fi
  done
fi

step "Done: $DIST"
