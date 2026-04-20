#!/bin/bash
set -e
TCDIR=/home/dareist/hk-invoke-toolchain
mkdir -p "$TCDIR"
cd "$TCDIR"

if [ ! -d gcc-linaro ]; then
    echo "Downloading Linaro ARM GCC 7.5..."
    wget -q "https://releases.linaro.org/components/toolchain/binaries/7.5-2019.12/arm-linux-gnueabihf/gcc-linaro-7.5.0-2019.12-x86_64_arm-linux-gnueabihf.tar.xz" -O toolchain.tar.xz
    echo "Extracting..."
    tar xJf toolchain.tar.xz
    mv gcc-linaro-7.5.0-2019.12-x86_64_arm-linux-gnueabihf gcc-linaro
    rm toolchain.tar.xz
    echo "Toolchain installed."
else
    echo "Toolchain already present."
fi

"$TCDIR/gcc-linaro/bin/arm-linux-gnueabihf-gcc" --version | head -1