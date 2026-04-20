#!/bin/bash
# Cross-compile shairport-sync + invoke-ctl for HK Invoke
# Target: ARMv7 hard-float (Marvell Berlin SoC), Linux 3.8.13, glibc 2.23
#
# Phase 1: Classic AirPlay (simpler, fewer deps)
# Phase 2: Upgrade to AirPlay 2 (future — needs avahi, libsodium, nqptp, FFmpeg)
#
# Uses the Linaro GCC 7.5 toolchain (no sudo required).
# Run in WSL:
#   bash /mnt/c/Users/dareist/source/repos/hk-invoke-airplay/scripts/cross-compile.sh
#
# Output: build/staging/bin/ contains ARM binaries

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET=arm-linux-gnueabihf

# Auto-detect environment: Docker container vs WSL with Linaro toolchain
if command -v ${TARGET}-gcc &>/dev/null; then
    # Docker or system cross-compiler in PATH
    echo "[env] Using system cross-compiler"
    CC="${TARGET}-gcc"
    CXX="${TARGET}-g++"
    AR="${TARGET}-ar"
    RANLIB="${TARGET}-ranlib"
    STRIP="${TARGET}-strip"
    PROJECT_DIR="${PROJECT_DIR:-/project}"
elif [ -d "/home/dareist/hk-invoke-toolchain/gcc-linaro" ]; then
    # WSL with Linaro toolchain
    echo "[env] Using Linaro toolchain"
    TC_DIR="/home/dareist/hk-invoke-toolchain/gcc-linaro"
    CC="$TC_DIR/bin/${TARGET}-gcc"
    CXX="$TC_DIR/bin/${TARGET}-g++"
    AR="$TC_DIR/bin/${TARGET}-ar"
    RANLIB="$TC_DIR/bin/${TARGET}-ranlib"
    STRIP="$TC_DIR/bin/${TARGET}-strip"
    PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
else
    echo "ERROR: No ARM cross-compiler found."
    echo "  Run in Docker:  docker build -t hk-invoke-build -f scripts/Dockerfile.build ."
    echo "  Or install Linaro toolchain to /home/dareist/hk-invoke-toolchain/gcc-linaro"
    exit 1
fi

BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
SRC_DIR="$BUILD_DIR/src"
SYSROOT="$BUILD_DIR/sysroot"
STAGING="$BUILD_DIR/staging"

# Compiler flags matching the Invoke's ARMv7 + NEON
CFLAGS="-march=armv7-a -mfpu=neon -mfloat-abi=hard -O2 -I${SYSROOT}/usr/include"
CXXFLAGS="$CFLAGS"
LDFLAGS="-L${SYSROOT}/usr/lib"

export CC CXX AR RANLIB STRIP CFLAGS CXXFLAGS LDFLAGS
export PKG_CONFIG_PATH="${SYSROOT}/usr/lib/pkgconfig:${SYSROOT}/usr/share/pkgconfig"
# Do NOT set PKG_CONFIG_SYSROOT_DIR — .pc files already have absolute sysroot paths
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib/pkgconfig"

# Versions
ALSA_LIB_VERSION="1.1.2"
OPENSSL_VERSION="1.0.2u"
LIBCONFIG_VERSION="1.7.3"
LIBPOPT_VERSION="1.19"
SHAIRPORT_SYNC_VERSION="3.3.9"

echo "========================================="
echo "HK Invoke AirPlay Cross-Compilation"
echo "========================================="
echo "Compiler: $($CC --version | head -1)"
echo "Target: $TARGET"
echo "Sysroot: $SYSROOT"
echo "Build: $BUILD_DIR"
echo ""

# --- Setup ---
setup() {
    echo ">>> Setting up directories..."
    mkdir -p "$SRC_DIR" "$SYSROOT/usr/lib/pkgconfig" "$SYSROOT/usr/include" "$STAGING/bin" "$STAGING/lib"
}

# --- Step 1: Build ALSA lib (need headers to compile shairport-sync) ---
build_alsa_lib() {
    echo ">>> [1/5] Building alsa-lib ${ALSA_LIB_VERSION} (for headers)..."
    cd "$SRC_DIR"

    if [ ! -d "alsa-lib-${ALSA_LIB_VERSION}" ]; then
        echo "  Downloading..."
        wget -q "https://www.alsa-project.org/files/pub/lib/alsa-lib-${ALSA_LIB_VERSION}.tar.bz2" -O alsa-lib.tar.bz2
        tar xjf alsa-lib.tar.bz2
        rm alsa-lib.tar.bz2
    fi

    cd "alsa-lib-${ALSA_LIB_VERSION}"
    if [ ! -f "$SYSROOT/usr/lib/libasound.so" ]; then
        ./configure \
            --host="$TARGET" \
            --prefix="$SYSROOT/usr" \
            --disable-python \
            --disable-old-symbols \
            --with-softfloat=no \
            --enable-shared --disable-static
        make -j"$(nproc)"
        make install
        echo "  alsa-lib installed to sysroot."
    else
        echo "  alsa-lib already in sysroot, skipping."
    fi
}

# --- Step 2: Build OpenSSL 1.0.2 (match device version for ABI compat) ---
build_openssl() {
    echo ">>> [2/5] Building OpenSSL ${OPENSSL_VERSION} (for headers)..."
    cd "$SRC_DIR"

    if [ ! -d "openssl-${OPENSSL_VERSION}" ]; then
        echo "  Downloading..."
        wget -q "https://github.com/openssl/openssl/releases/download/OpenSSL_1_0_2u/openssl-${OPENSSL_VERSION}.tar.gz" -O openssl.tar.gz || \
        wget -q "https://www.openssl.org/source/old/1.0.2/openssl-${OPENSSL_VERSION}.tar.gz" -O openssl.tar.gz
        tar xzf openssl.tar.gz
        rm openssl.tar.gz
    fi

    cd "openssl-${OPENSSL_VERSION}"
    if [ ! -f "$SYSROOT/usr/lib/libssl.so" ]; then
        # OpenSSL uses its own Configure script, not autoconf
        ./Configure linux-armv4 \
            --prefix="$SYSROOT/usr" \
            --openssldir="$SYSROOT/usr/ssl" \
            shared \
            -march=armv7-a -mfpu=neon -mfloat-abi=hard
        make CC="$CC" AR="$AR r" RANLIB="$RANLIB" -j"$(nproc)" 2>&1 | tail -5
        make install_sw
        echo "  OpenSSL installed to sysroot."
    else
        echo "  OpenSSL already in sysroot, skipping."
    fi
}

# --- Step 3: Build libconfig (shairport-sync dependency) ---
build_libconfig() {
    echo ">>> [3/5] Building libconfig ${LIBCONFIG_VERSION}..."
    cd "$SRC_DIR"

    if [ ! -d "libconfig-${LIBCONFIG_VERSION}" ]; then
        echo "  Downloading..."
        wget -q "https://github.com/hyperrealm/libconfig/releases/download/v${LIBCONFIG_VERSION}/libconfig-${LIBCONFIG_VERSION}.tar.gz"
        tar xzf "libconfig-${LIBCONFIG_VERSION}.tar.gz"
        rm "libconfig-${LIBCONFIG_VERSION}.tar.gz"
    fi

    cd "libconfig-${LIBCONFIG_VERSION}"
    if [ ! -f "$SYSROOT/usr/lib/libconfig.a" ]; then
        ./configure \
            --host="$TARGET" \
            --prefix="$SYSROOT/usr" \
            --disable-shared --enable-static \
            --disable-cxx
        make -j"$(nproc)"
        make install
        echo "  libconfig done."
    else
        echo "  libconfig already built, skipping."
    fi
}

# --- Step 4: Build popt (shairport-sync dependency) ---
build_popt() {
    echo ">>> [4/5] Building popt ${LIBPOPT_VERSION}..."
    cd "$SRC_DIR"

    if [ ! -d "popt-${LIBPOPT_VERSION}" ]; then
        echo "  Downloading..."
        wget -q "http://ftp.rpm.org/popt/releases/popt-1.x/popt-${LIBPOPT_VERSION}.tar.gz"
        tar xzf "popt-${LIBPOPT_VERSION}.tar.gz"
        rm "popt-${LIBPOPT_VERSION}.tar.gz"
    fi

    cd "popt-${LIBPOPT_VERSION}"
    if [ ! -f "$SYSROOT/usr/lib/libpopt.a" ]; then
        ./configure \
            --host="$TARGET" \
            --prefix="$SYSROOT/usr" \
            --disable-shared --enable-static
        make -j"$(nproc)"
        make install
        echo "  popt done."
    else
        echo "  popt already built, skipping."
    fi
}

# --- Step 5: Build shairport-sync (Classic AirPlay) ---
build_shairport_sync() {
    echo ">>> [5/5] Building shairport-sync ${SHAIRPORT_SYNC_VERSION} (Classic AirPlay)..."
    cd "$SRC_DIR"

    if [ ! -d "shairport-sync" ]; then
        echo "  Cloning..."
        git clone --depth 1 --branch "${SHAIRPORT_SYNC_VERSION}" \
            https://github.com/mikebrady/shairport-sync.git
    fi

    cd shairport-sync

    # Clean any prior build
    [ -f Makefile ] && make clean 2>/dev/null || true

    autoreconf -fi 2>&1 | tail -3

    # Classic AirPlay with built-in mDNS (tinysvcmdns) — no external deps
    # 3.3.x configure flags
    ./configure \
        --host="$TARGET" \
        --prefix="/usr" \
        --sysconfdir=/etc \
        --with-alsa \
        --with-tinysvcmdns \
        --with-ssl=openssl \
        --with-metadata \
        CFLAGS="$CFLAGS" \
        LDFLAGS="$LDFLAGS"

    make -j"$(nproc)"
    cp shairport-sync "$STAGING/bin/"
    echo "  shairport-sync done."
}

# --- Build invoke-ctl ---
build_invoke_ctl() {
    echo ">>> Building invoke-ctl..."
    local src="$PROJECT_DIR/src/invoke-ctl/invoke-ctl.c"
    if [ -f "$src" ]; then
        "$CC" $CFLAGS \
            -o "$STAGING/bin/invoke-ctl" \
            "$src" \
            -lpthread
        echo "  invoke-ctl done."
    else
        echo "  ERROR: $src not found"
        return 1
    fi
}

# --- Verify ---
verify() {
    echo ""
    echo "========================================="
    echo "Build Results"
    echo "========================================="

    for bin in "$STAGING/bin/"*; do
        local name
        name=$(basename "$bin")
        local arch
        arch=$(file "$bin" | grep -o 'ELF.*' | head -c 70)
        printf "  %-20s %s\n" "$name" "$arch"

        # Check glibc version requirements
        local max_glibc
        max_glibc=$(readelf -V "$bin" 2>/dev/null | grep "GLIBC_" | grep -oP 'GLIBC_[\d.]+' | sort -V | tail -1)
        if [ -n "$max_glibc" ]; then
            printf "  %-20s needs %s (device has GLIBC_2.23)\n" "" "$max_glibc"
            # Warn if higher than 2.23
            local ver
            ver=$(echo "$max_glibc" | grep -oP '[\d.]+')
            if [ "$(printf '%s\n' "2.23" "$ver" | sort -V | head -1)" != "$ver" ] && [ "$ver" != "2.23" ]; then
                echo "  ⚠️  WARNING: $name needs $max_glibc but device only has GLIBC_2.23!"
            fi
        fi
    done

    echo ""
    echo "Binaries: $STAGING/bin/"
    ls -la "$STAGING/bin/"
    echo ""

    # Strip binaries for smaller size
    echo "Stripping binaries..."
    for bin in "$STAGING/bin/"*; do
        local before after
        before=$(stat -c%s "$bin")
        "$STRIP" "$bin" 2>/dev/null || true
        after=$(stat -c%s "$bin")
        printf "  %-20s %s → %s\n" "$(basename "$bin")" "$(numfmt --to=iec $before)" "$(numfmt --to=iec $after)"
    done
}

# --- Main ---
setup
build_alsa_lib
build_openssl
build_libconfig
build_popt
build_shairport_sync
build_invoke_ctl
verify

echo ""
echo "Cross-compilation complete!"
echo "Next: run scripts/build-rootfs.sh to create the modified firmware image."
