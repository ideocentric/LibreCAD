#!/bin/bash
set -euxo pipefail

# Build a minimal, static, universal (arm64 + x86_64) Freetype for macOS.
#
# ttf2lff links Freetype, but Homebrew ships a thin (single-arch) Freetype, so a
# universal LibreCAD build cannot link the x86_64 slice of ttf2lff. ttf2lff only
# needs Freetype's core TrueType outline reading, so we build a self-contained
# static library with the optional dependencies disabled (no libpng, harfbuzz,
# brotli, bzip2 or external zlib) - this avoids pulling in further thin dylibs.
#
# Usage: build-universal-freetype-macos.sh <install-prefix>
# Then point the build at it with FREETYPE_DIR=<install-prefix>.

PREFIX="${1:?usage: $0 <install-prefix>}"
FT_VER="${FREETYPE_VERSION:-2.13.3}"

WORK="$(mktemp -d)"
cd "$WORK"
curl -Ls -o freetype.tar.gz \
    "https://download.savannah.gnu.org/releases/freetype/freetype-${FT_VER}.tar.gz"
tar xf freetype.tar.gz
cd "freetype-${FT_VER}"

./configure --prefix="$PREFIX" \
    --enable-static --disable-shared \
    --without-harfbuzz --without-png --without-brotli --without-bzip2 --without-zlib \
    CFLAGS="-arch arm64 -arch x86_64" \
    LDFLAGS="-arch arm64 -arch x86_64"
make -j"$(sysctl -n hw.ncpu)"
make install

echo "Built universal Freetype at $PREFIX"
lipo -info "$PREFIX/lib/libfreetype.a"