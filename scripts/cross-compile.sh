#!/bin/bash
# Cross-compile shairport-sync 5.x + nqptp + dependencies for HK Invoke
# Target: ARMv7 hard-float, Linux 3.8.13-yocto-standard, glibc
#
# Run this in WSL (Ubuntu) with:
#   sudo bash scripts/cross-compile.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
STAGING_DIR="$BUILD_DIR/staging"
SYSROOT="$STAGING_DIR/sysroot"
PREFIX="/usr"

# Target triple for ARMv7 hard-float
TARGET=arm-linux-gnueabihf
TOOLCHAIN_PREFIX="${TARGET}-"

# Compiler flags matching the Invoke's kernel/userspace
export CFLAGS="-march=armv7-a -mfpu=neon -mfloat-abi=hard -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L${SYSROOT}/usr/lib"
export PKG_CONFIG_PATH="${SYSROOT}/usr/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"

# Source versions
SHAIRPORT_SYNC_VERSION="4.3.4"
NQPTP_VERSION="1.2.4"
LIBCONFIG_VERSION="1.7.3"
LIBPOPT_VERSION="1.19"
LIBSODIUM_VERSION="1.0.20"

echo "========================================="
echo "HK Invoke AirPlay Cross-Compilation"
echo "========================================="
echo "Target: $TARGET"
echo "Build dir: $BUILD_DIR"
echo "Staging: $STAGING_DIR"
echo ""

# --- Step 0: Install cross-compilation toolchain ---
install_toolchain() {
    echo ">>> Installing cross-compilation toolchain..."
    apt-get update -qq
    apt-get install -y -qq \
        gcc-${TARGET} g++-${TARGET} \
        autoconf automake libtool pkg-config \
        git wget curl \
        xxd \
        2>/dev/null
    
    # Verify
    ${TOOLCHAIN_PREFIX}gcc --version | head -1
    echo "Toolchain ready."
}

# --- Step 1: Create build directories ---
setup_dirs() {
    echo ">>> Setting up directories..."
    mkdir -p "$BUILD_DIR/src"
    mkdir -p "$STAGING_DIR"/{bin,lib,etc}
    mkdir -p "$SYSROOT/usr/"{lib,include}
    echo "Directories ready."
}

# --- Step 2: Build libconfig (shairport-sync dependency) ---
build_libconfig() {
    echo ">>> Building libconfig ${LIBCONFIG_VERSION}..."
    cd "$BUILD_DIR/src"
    
    if [ ! -d "libconfig-${LIBCONFIG_VERSION}" ]; then
        wget -q "https://hyperrealm.github.io/libconfig/dist/libconfig-${LIBCONFIG_VERSION}.tar.gz"
        tar xzf "libconfig-${LIBCONFIG_VERSION}.tar.gz"
    fi
    
    cd "libconfig-${LIBCONFIG_VERSION}"
    ./configure \
        --host="$TARGET" \
        --prefix="$SYSROOT/usr" \
        --disable-shared \
        --enable-static \
        CC="${TOOLCHAIN_PREFIX}gcc" \
        CXX="${TOOLCHAIN_PREFIX}g++"
    
    make -j$(nproc) clean 2>/dev/null || true
    make -j$(nproc)
    make install
    echo "libconfig built."
}

# --- Step 3: Build popt (shairport-sync dependency) ---
build_popt() {
    echo ">>> Building popt ${LIBPOPT_VERSION}..."
    cd "$BUILD_DIR/src"
    
    if [ ! -d "popt-${LIBPOPT_VERSION}" ]; then
        wget -q "https://ftp.rpm.org/popt/releases/popt-1.x/popt-${LIBPOPT_VERSION}.tar.gz"
        tar xzf "popt-${LIBPOPT_VERSION}.tar.gz"
    fi
    
    cd "popt-${LIBPOPT_VERSION}"
    ./configure \
        --host="$TARGET" \
        --prefix="$SYSROOT/usr" \
        --disable-shared \
        --enable-static \
        CC="${TOOLCHAIN_PREFIX}gcc"
    
    make -j$(nproc) clean 2>/dev/null || true
    make -j$(nproc)
    make install
    echo "popt built."
}

# --- Step 4: Build libsodium (shairport-sync AirPlay 2 dependency) ---
build_libsodium() {
    echo ">>> Building libsodium ${LIBSODIUM_VERSION}..."
    cd "$BUILD_DIR/src"
    
    if [ ! -d "libsodium-${LIBSODIUM_VERSION}" ]; then
        wget -q "https://download.libsodium.org/libsodium/releases/libsodium-${LIBSODIUM_VERSION}.tar.gz"
        tar xzf "libsodium-${LIBSODIUM_VERSION}.tar.gz"
    fi
    
    cd "libsodium-${LIBSODIUM_VERSION}"
    ./configure \
        --host="$TARGET" \
        --prefix="$SYSROOT/usr" \
        --disable-shared \
        --enable-static \
        CC="${TOOLCHAIN_PREFIX}gcc"
    
    make -j$(nproc) clean 2>/dev/null || true
    make -j$(nproc)
    make install
    echo "libsodium built."
}

# --- Step 5: Build nqptp (PTP timing daemon for AirPlay 2) ---
build_nqptp() {
    echo ">>> Building nqptp ${NQPTP_VERSION}..."
    cd "$BUILD_DIR/src"
    
    if [ ! -d "nqptp" ]; then
        git clone --depth 1 --branch "${NQPTP_VERSION}" https://github.com/mikebrady/nqptp.git
    fi
    
    cd nqptp
    autoreconf -fi
    ./configure \
        --host="$TARGET" \
        --prefix="$PREFIX" \
        CC="${TOOLCHAIN_PREFIX}gcc"
    
    make -j$(nproc) clean 2>/dev/null || true
    make -j$(nproc)
    
    cp nqptp "$STAGING_DIR/bin/"
    echo "nqptp built."
}

# --- Step 6: Build shairport-sync (AirPlay 2 receiver) ---
build_shairport_sync() {
    echo ">>> Building shairport-sync ${SHAIRPORT_SYNC_VERSION}..."
    cd "$BUILD_DIR/src"
    
    if [ ! -d "shairport-sync" ]; then
        git clone --depth 1 --branch "${SHAIRPORT_SYNC_VERSION}" https://github.com/mikebrady/shairport-sync.git
    fi
    
    cd shairport-sync
    autoreconf -fi
    
    # Configure with AirPlay 2 support + ALSA output
    # Note: --with-apple-alac for Apple Lossless codec support
    # Note: --with-airplay-2 requires libsodium + nqptp
    ./configure \
        --host="$TARGET" \
        --prefix="$PREFIX" \
        --with-alsa \
        --with-airplay-2 \
        --with-avahi=no \
        --with-dns_sd \
        --with-ssl=openssl \
        --with-metadata \
        --with-apple-alac \
        CC="${TOOLCHAIN_PREFIX}gcc" \
        CFLAGS="$CFLAGS -I${SYSROOT}/usr/include" \
        LDFLAGS="$LDFLAGS -L${SYSROOT}/usr/lib" \
        PKG_CONFIG_PATH="$PKG_CONFIG_PATH"
    
    make -j$(nproc) clean 2>/dev/null || true
    make -j$(nproc)
    
    cp shairport-sync "$STAGING_DIR/bin/"
    echo "shairport-sync built."
}

# --- Step 7: Build invoke-ctl (control daemon) ---
build_invoke_ctl() {
    echo ">>> Building invoke-ctl..."
    
    if [ -f "$PROJECT_DIR/src/invoke-ctl/invoke-ctl.c" ]; then
        ${TOOLCHAIN_PREFIX}gcc $CFLAGS \
            -o "$STAGING_DIR/bin/invoke-ctl" \
            "$PROJECT_DIR/src/invoke-ctl/invoke-ctl.c" \
            -lpthread
        echo "invoke-ctl built."
    else
        echo "invoke-ctl source not found, skipping."
    fi
}

# --- Step 8: Verify binaries ---
verify() {
    echo ""
    echo "========================================="
    echo "Build Results"
    echo "========================================="
    for bin in "$STAGING_DIR/bin/"*; do
        echo -n "$(basename "$bin"): "
        file "$bin" | grep -o 'ARM.*'
    done
    echo ""
    echo "All binaries in: $STAGING_DIR/bin/"
    echo "Libraries in: $SYSROOT/usr/lib/"
}

# --- Main ---
install_toolchain
setup_dirs
build_libconfig
build_popt
build_libsodium
build_nqptp
build_shairport_sync
build_invoke_ctl
verify

echo ""
echo "Cross-compilation complete!"
echo "Next: run scripts/build-rootfs.sh to create the modified firmware image."
