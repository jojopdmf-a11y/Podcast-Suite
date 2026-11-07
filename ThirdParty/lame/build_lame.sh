#!/bin/zsh
# Build unmodified LAME 3.100 as a replaceable arm64 shared library.
# LGPL 2.x section 6 lets an app use the library when it is a separate
# dynamic library the user can swap out. This script does not copy LAME
# into the app binary. Decode support is left out; playback stays on
# AVFoundation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
SRC="$BUILD/src"
PREFIX="$BUILD/prefix"
LIBDIR="$BUILD/lib"
TARBALL="$SRC/lame-3.100.tar.gz"
DYLIB="$LIBDIR/libmp3lame.0.dylib"
COPYING="$BUILD/COPYING"
SHA256="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
URL="https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz"

if [[ -f "$DYLIB" && -f "$COPYING" ]]; then
  archs="$(lipo -archs "$DYLIB" 2>/dev/null || true)"
  ident="$(otool -D "$DYLIB" 2>/dev/null | tail -n 1 || true)"
  if [[ "$archs" == "arm64" && "$ident" == "@rpath/libmp3lame.0.dylib" ]]; then
    echo "Using cached $DYLIB"
    exit 0
  fi
fi

mkdir -p "$SRC" "$LIBDIR"

download() {
  echo "Downloading lame-3.100.tar.gz"
  curl -L --fail --retry 3 --retry-delay 2 -o "$TARBALL.partial" "$URL"
  mv "$TARBALL.partial" "$TARBALL"
}

verify() {
  local actual
  actual="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
  if [[ "$actual" != "$SHA256" ]]; then
    echo "SHA-256 mismatch for lame-3.100.tar.gz" >&2
    echo "expected $SHA256" >&2
    echo "actual   $actual" >&2
    return 1
  fi
}

if [[ ! -f "$TARBALL" ]]; then
  download
fi
if ! verify; then
  rm -f "$TARBALL"
  download
  verify
fi

file "$TARBALL" | grep -q 'gzip compressed'
rm -rf "$SRC/lame-3.100" "$PREFIX"
tar -xzf "$TARBALL" -C "$SRC"
cp "$SRC/lame-3.100/COPYING" "$COPYING"
chmod +x "$SRC/lame-3.100/configure"

# Flags only. The LAME sources are not patched.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
cd "$SRC/lame-3.100"
./configure \
  --prefix="$PREFIX" \
  --disable-decoder \
  --disable-frontend \
  --disable-static \
  --enable-shared \
  CC="clang" \
  CFLAGS="-arch arm64 -O2 -Wno-error=implicit-function-declaration -Wno-implicit-function-declaration -Wno-deprecated-non-prototype -Wno-strict-prototypes -include strings.h" \
  LDFLAGS="-arch arm64"

# libmp3lame.sym still names decode symbols and lame_init_old. With
# --disable-decoder those symbols are not compiled, and -export-symbols
# then fails the link. Drop that list at build time. The sources stay
# as shipped, and the dylib only contains the code configure built.
make -j"$(sysctl -n hw.ncpu)" \
  libmp3lame_la_LDFLAGS="-version-info 0:0 -no-undefined"
make install \
  libmp3lame_la_LDFLAGS="-version-info 0:0 -no-undefined"

installed="$(find "$PREFIX" -name 'libmp3lame.0.dylib' | head -n 1)"
if [[ -z "$installed" ]]; then
  echo "libmp3lame.0.dylib was not installed." >&2
  exit 1
fi
cp "$installed" "$DYLIB"
chmod 755 "$DYLIB"
install_name_tool -id "@rpath/libmp3lame.0.dylib" "$DYLIB"

ident="$(otool -D "$DYLIB" | tail -n 1)"
if [[ "$ident" != "@rpath/libmp3lame.0.dylib" ]]; then
  echo "Install name is '$ident', expected @rpath/libmp3lame.0.dylib" >&2
  exit 1
fi
if otool -L "$DYLIB" | grep -F "$PREFIX" >/dev/null; then
  echo "libmp3lame still references the build directory." >&2
  otool -L "$DYLIB" >&2
  exit 1
fi
archs="$(lipo -archs "$DYLIB")"
if [[ "$archs" != "arm64" ]]; then
  echo "libmp3lame arch is '$archs', expected arm64." >&2
  exit 1
fi

if nm -gU "$DYLIB" | grep -E '_(hip_decode|lame_decode|mpg123_)' >/dev/null; then
  echo "Decoder symbols are in libmp3lame. Configure with --disable-decoder." >&2
  nm -gU "$DYLIB" | grep -E '_(hip_decode|lame_decode|mpg123_)' >&2
  exit 1
fi

for sym in lame_init lame_encode_buffer_ieee_float lame_encode_buffer_interleaved_ieee_float lame_encode_flush lame_get_lametag_frame lame_set_brate lame_close; do
  if ! nm -gU "$DYLIB" | grep -q " _${sym}$"; then
    echo "libmp3lame is missing _${sym}." >&2
    exit 1
  fi
done

echo "Built $DYLIB"
otool -L "$DYLIB"
