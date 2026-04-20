#!/bin/bash
TC=/home/dareist/hk-invoke-toolchain/gcc-linaro
echo "=== lib contents ==="
ls "$TC/arm-linux-gnueabihf/libc/lib/"
echo "=== glibc version ==="
strings "$TC/arm-linux-gnueabihf/libc/lib/libc.so.6" 2>/dev/null | grep "GLIBC_" | sort -V | tail -5
echo "=== compiler version ==="
"$TC/bin/arm-linux-gnueabihf-gcc" --version | head -1
echo "=== sysroot ==="
"$TC/bin/arm-linux-gnueabihf-gcc" -print-sysroot