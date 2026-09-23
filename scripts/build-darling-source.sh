#!/usr/bin/env bash
#
# build-darling-source.sh - compile Darling directly from source.
#
# Clones darlinghq/darling with all submodules, installs build dependencies,
# configures CMake with Ninja, compiles the Darwin runtime & userland,
# and either packages deb files or installs directly into a target directory.
#
# Usage:
#   sudo ./scripts/build-darling-source.sh [DESTDIR]
#
# If DESTDIR is provided, Darling is installed directly into $DESTDIR/usr.
# Otherwise, binary .deb packages are built via tools/debian/make-deb and
# copied into build/packages/.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
SRC_DIR="${SRC_DIR:-$BUILD_DIR/darling-source}"
OUTPUT_DEBS_DIR="${OUTPUT_DEBS_DIR:-$BUILD_DIR/packages}"
DESTDIR="${1:-}"

DARLING_REPO="${DARLING_REPO:-https://github.com/darlinghq/darling.git}"
DARLING_BRANCH="${DARLING_BRANCH:-master}"

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

log "Installing host compilation dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  cmake \
  ninja-build \
  clang \
  bison \
  flex \
  pkg-config \
  git \
  git-lfs \
  libfuse-dev \
  libudev-dev \
  libcairo2-dev \
  libgl1-mesa-dev \
  libglu1-mesa-dev \
  libtiff-dev \
  libfreetype6-dev \
  libxml2-dev \
  libegl1-mesa-dev \
  libfontconfig1-dev \
  libbsd-dev \
  libxrandr-dev \
  libxcursor-dev \
  libgif-dev \
  libavutil-dev \
  libpulse-dev \
  libavformat-dev \
  libavcodec-dev \
  libswresample-dev \
  libdbus-1-dev \
  libxkbfile-dev \
  libssl-dev \
  devscripts \
  debhelper \
  equivs

# --- Clone source repository --------------------------------------------------
mkdir -p "$BUILD_DIR"
if [ ! -d "$SRC_DIR/.git" ]; then
  log "Cloning Darling repository ($DARLING_BRANCH) with submodules"
  export GIT_CLONE_PROTECTION_ACTIVE=false
  git clone --depth 1 --branch "$DARLING_BRANCH" --recursive "$DARLING_REPO" "$SRC_DIR"
else
  log "Using existing source checkout in $SRC_DIR"
fi

cd "$SRC_DIR"
git lfs install || true

# --- Compile or Package -------------------------------------------------------
if [ -n "$DESTDIR" ]; then
  log "Configuring CMake for direct install into DESTDIR: $DESTDIR"
  mkdir -p "$SRC_DIR/build"
  cd "$SRC_DIR/build"

  cmake .. -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DTARGET_i386=OFF \
    -DJSC_UNIFIED_BUILD=ON

  log "Compiling Darling with Ninja (cores: $(nproc))"
  ninja

  log "Installing into $DESTDIR"
  DESTDIR="$DESTDIR" ninja install
else
  log "Building Debian packages via tools/debian/make-deb"
  mkdir -p "$OUTPUT_DEBS_DIR"
  ./tools/debian/make-deb

  log "Moving generated .deb packages to $OUTPUT_DEBS_DIR"
  mv ../*.deb "$OUTPUT_DEBS_DIR/" 2>/dev/null || true
  ls -lh "$OUTPUT_DEBS_DIR"
fi

log "Darling build complete!"
