#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# Set ARCHS to build a universal binary, e.g. ARCHS="arm64 x86_64" as the
# release workflow does. Left unset it builds for the host only, which is what
# local permission testing wants — and unlike a multi-arch build, it does not
# require a full Xcode install.
ARCH_FLAGS=""
for arch in ${ARCHS:-}; do
    ARCH_FLAGS="$ARCH_FLAGS --arch $arch"
done

# Arch names are single words, so the intended splitting here is safe.
# shellcheck disable=SC2086
swift build -c release $ARCH_FLAGS
# Ask SwiftPM where the product landed rather than hardcoding a path: the
# layout differs between host-only and multi-arch builds.
# shellcheck disable=SC2086
BIN_DIR=$(swift build -c release $ARCH_FLAGS --show-bin-path)

APP="$ROOT/Build/Steno.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Steno" "$APP/Contents/MacOS/Steno"
cp "Sources/StenoApp/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sign the whole bundle (not just the linker's ad-hoc signature on the raw
# binary) so Info.plist/Resources are sealed and TCC gets a stable identity
# across rebuilds. Without this, mic permission silently fails to attach
# after reinstalling.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
