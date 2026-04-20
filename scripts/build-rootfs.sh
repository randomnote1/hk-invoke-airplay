#!/bin/bash
# Build a modified rootfs image for the HK Invoke AirPlay speaker.
#
# This script:
#   1. Extracts the ADB-enabled rootfs from 83_IMAGE
#   2. Removes Cortana/Libre services
#   3. Installs shairport-sync + invoke-ctl
#   4. Patches init.rc for AirPlay boot
#   5. Disables WiFi/BT module loading
#   6. Configures USB gadget Ethernet with DHCP
#   7. Repacks into a flashable 83_IMAGE
#
# Prerequisites:
#   - Run cross-compile.sh first (or have binaries in build/output/bin/)
#   - squashfs-tools installed
#   - Python 3 for image rebuild
#
# Usage (run in WSL as root):
#   sudo bash scripts/build-rootfs.sh <path-to-83_IMAGE_ADB>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
STAGING_DIR="$BUILD_DIR/output"
ROOTFS_DIR="$BUILD_DIR/rootfs"
OVERLAY_DIR="$PROJECT_DIR/rootfs"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <path-to-83_IMAGE_ADB>"
    exit 1
fi

IMAGE_PATH="$1"

if [ ! -f "$IMAGE_PATH" ]; then
    echo "Error: $IMAGE_PATH not found"
    exit 1
fi

echo "========================================="
echo "HK Invoke Rootfs Builder"
echo "========================================="

# --- Step 1: Extract rootfs from 83_IMAGE ---
extract_rootfs() {
    echo ">>> Extracting rootfs from 83_IMAGE..."

    python3 -c "
import sys
data = open('$IMAGE_PATH', 'rb').read()
offset = 64
image_offset = 640
for i in range(9):
    region = data[offset:offset+64]
    name = region[0:16].decode('utf-8').rstrip('\x00')
    size = int.from_bytes(region[16:20], 'little')
    if name == 'rootfs':
        print(f'Found rootfs at offset {image_offset}, size {size} bytes ({size//1048576} MB)')
        with open('$BUILD_DIR/rootfs.bin', 'wb') as f:
            f.write(data[image_offset:image_offset+size])
        break
    offset += 64
    image_offset += size
"

    rm -rf "$ROOTFS_DIR"
    unsquashfs -f -no-xattrs -d "$ROOTFS_DIR" "$BUILD_DIR/rootfs.bin"
    echo "  Rootfs extracted: $(find "$ROOTFS_DIR" -type f | wc -l) files"
}

# --- Step 2: Remove Cortana/Libre services ---
strip_cortana() {
    echo ">>> Removing Cortana and Libre services..."

    rm -f "$ROOTFS_DIR/usr/bin/system-manager"
    rm -rf "$ROOTFS_DIR/etc/podium"
    rm -f "$ROOTFS_DIR/usr/bin/run-podium.sh"

    local remove_bins=(
        LibreManager yani_service luci_service MessageBoxHandler
        LibreEnv firstboot certgen LUCI_local servicemanager
        mediaserver BluetoothSystem spotify
        copy.sh copy_eng.sh
        startDDMSAP.sh startHostAP.sh start_softap.sh start_webserver.sh
    )
    for bin in "${remove_bins[@]}"; do
        rm -f "$ROOTFS_DIR/system/bin/$bin" 2>/dev/null || true
    done

    rm -f "$ROOTFS_DIR/sbin/wpa_supplicant_setup.sh"
    echo "  Done."
}

# --- Step 3: Disable WiFi/BT kernel modules ---
disable_wireless() {
    echo ">>> Disabling WiFi/BT kernel modules..."

    local modules_dir="$ROOTFS_DIR/lib/modules/3.8.13-yocto-standard"

    # Remove WiFi driver modules
    rm -rf "$modules_dir/kernel/arch/arm/mach-berlin/modules/wlan_sd8887" 2>/dev/null || true
    rm -rf "$modules_dir/wlan_sd8887" 2>/dev/null || true

    # Remove Bluetooth driver modules
    rm -f "$modules_dir/kernel/drivers/bluetooth/btmrvl.ko" 2>/dev/null || true
    rm -rf "$modules_dir/kernel/arch/arm/mach-berlin/modules/bt_sd8887" 2>/dev/null || true

    rm -rf "$ROOTFS_DIR/bluetooth" 2>/dev/null || true
    echo "  Done."
}

# --- Step 4: Install shairport-sync and invoke-ctl ---
install_airplay() {
    echo ">>> Installing AirPlay binaries..."

    for bin in shairport-sync invoke-ctl; do
        if [ -f "$STAGING_DIR/bin/$bin" ]; then
            cp "$STAGING_DIR/bin/$bin" "$ROOTFS_DIR/usr/bin/"
            chmod 755 "$ROOTFS_DIR/usr/bin/$bin"
            echo "  Installed $bin"
        else
            echo "  WARNING: $bin not found in $STAGING_DIR/bin/"
        fi
    done

    # Copy any shared libraries from staging
    if [ -d "$STAGING_DIR/lib" ]; then
        cp -a "$STAGING_DIR/lib/"*.so* "$ROOTFS_DIR/usr/lib/" 2>/dev/null || true
    fi
}

# --- Step 5: Apply rootfs overlay (config files) ---
apply_overlay() {
    echo ">>> Applying rootfs overlay from $OVERLAY_DIR..."

    if [ -d "$OVERLAY_DIR/etc" ]; then
        cp -a "$OVERLAY_DIR/etc/"* "$ROOTFS_DIR/etc/" 2>/dev/null || true
        echo "  Config files applied."
    fi
}

# --- Step 6: Patch init.rc in-place ---
patch_init_rc() {
    echo ">>> Patching init.rc..."

    local initrc="$ROOTFS_DIR/init.rc"

    # 6a. Comment out wpa_supplicant service block
    sed -i '/^service wpa_supplicant /,/^$/s/^/#DISABLED /' "$initrc"

    # 6b. Comment out podium service
    sed -i '/^service podium /,/^$/s/^/#DISABLED /' "$initrc"

    # 6c. Comment out startup_ls6 service
    sed -i '/^service startup_ls6 /,/^$/s/^/#DISABLED /' "$initrc"

    # 6d. Comment out init_complete service
    sed -i '/^service init_complete /,/^$/s/^/#DISABLED /' "$initrc"

    # 6e. Comment out copy_env service
    sed -i '/^service copy_env /,/^$/s/^/#DISABLED /' "$initrc"

    # 6f. Comment out hostapd service
    sed -i '/^service hostapd /,/^$/s/^/#DISABLED /' "$initrc"

    # 6g. Comment out boot_complete service
    sed -i '/^service boot_complete /,/^$/s/^/#DISABLED /' "$initrc"

    # 6h. In "on boot" section, comment out starts for removed services
    sed -i 's/^\(    start init_complete\)/#DISABLED \1/' "$initrc"
    sed -i 's/^\(    start startup_ls6\)/#DISABLED \1/' "$initrc"
    sed -i 's/^\(    start podium\)/#DISABLED \1/' "$initrc"
    sed -i 's/^\(    start boot_complete\)/#DISABLED \1/' "$initrc"
    sed -i 's/^\(    start dnscacher\)/#DISABLED \1/' "$initrc"
    sed -i 's/^\(    wait \/data\/wifi\/up\)/#DISABLED \1/' "$initrc"
    sed -i 's/^\(    wait \/data\/wifi\/copied.conf\)/#DISABLED \1/' "$initrc"

    # 6i. Append new services at the end of init.rc
    cat >> "$initrc" << 'AIRPLAY_SERVICES'

# ============================================
# AirPlay Speaker Services (added by hk-invoke-airplay)
# ============================================

service shairport_sync /usr/bin/shairport-sync -c /etc/shairport-sync.conf
    user root
    group audio

service invoke_ctl /usr/bin/invoke-ctl
    user root
    group input audio

AIRPLAY_SERVICES

    # 6j. Add start commands for new services in "on boot"
    # Insert after "start serviceport" line
    sed -i '/start serviceport/a\    start shairport_sync\n    start invoke_ctl' "$initrc"

    echo "  init.rc patched."
}

# --- Step 7: Update serviceport.sh for DHCP ---
patch_serviceport() {
    echo ">>> Patching serviceport.sh for DHCP..."

    cat > "$ROOTFS_DIR/usr/sbin/serviceport.sh" << 'EOF'
#!/bin/sh
# Modified serviceport.sh — try DHCP first, fall back to static IP
# Original: static 172.20.20.20
# Modified: DHCP with static fallback for direct PC connection

file=/data/service-ip.txt
default=172.20.20.20
preverr=1

while true; do
    # Wait for eth0 to appear
    if ifconfig eth0 > /dev/null 2>&1 || ip link show eth0 > /dev/null 2>&1; then
        # Try DHCP first (timeout 10s)
        if ! pgrep -f "dhcpcd.*eth0" > /dev/null 2>&1; then
            dhcpcd eth0 -t 10 -h invoke-airplay --noarp 2>/dev/null &
        fi

        # Check if DHCP gave us an address
        current_ip=$(ip -4 addr show eth0 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
        if [ -z "$current_ip" ]; then
            # No DHCP address — use static fallback
            ip=$(grep -m1 '^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+$' $file 2>/dev/null || echo $default)
            ifconfig eth0 $ip up 2>/dev/null
            err=$?
            if [ $err -eq 0 ] && [ $preverr -ne 0 ]; then
                arping -q -U -c 1 -I eth0 $ip 2>/dev/null || true
            fi
            preverr=$err
        fi
    fi
    sleep 5
done
EOF
    chmod 755 "$ROOTFS_DIR/usr/sbin/serviceport.sh"
    echo "  Done."
}

# --- Step 8: Update hosts file ---
update_hosts() {
    echo ">>> Updating hosts file..."

    cat > "$ROOTFS_DIR/etc/hosts" << 'EOF'
127.0.0.1 localhost localhost.localdomain invoke-airplay

# IPv6
::1 localhost ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

# Block OTA updates and telemetry
127.0.0.1 redbend.com
127.0.0.1 saf1.redbend.com
127.0.0.1 neptune.redbend.com
127.0.0.1 harman-podium.redbend.com
EOF
    echo "  Done."
}

# --- Step 9: Repack rootfs ---
repack_rootfs() {
    echo ">>> Repacking rootfs as SquashFS..."

    rm -f "$BUILD_DIR/rootfs_new.bin"
    mksquashfs "$ROOTFS_DIR" "$BUILD_DIR/rootfs_new.bin" \
        -b 131072 \
        -comp gzip \
        -noappend \
        -no-xattrs

    local new_size
    new_size=$(stat -c%s "$BUILD_DIR/rootfs_new.bin")
    local max_size=$((720 * 131072))  # 90 MB

    echo "  New rootfs: $new_size bytes ($((new_size / 1048576)) MB)"
    echo "  Max allowed: $max_size bytes ($((max_size / 1048576)) MB)"

    if [ "$new_size" -gt "$max_size" ]; then
        echo "ERROR: Rootfs exceeds partition limit!"
        exit 1
    fi
}

# --- Step 10: Rebuild 83_IMAGE ---
rebuild_image() {
    echo ">>> Rebuilding 83_IMAGE..."

    python3 << PYEOF
import zlib

data = bytearray(open('$IMAGE_PATH', 'rb').read())
new_rootfs = open('$BUILD_DIR/rootfs_new.bin', 'rb').read()

offset = 64
image_offset = 640

for i in range(9):
    region = bytearray(data[offset:offset+64])
    name = region[0:16].decode('utf-8').rstrip('\x00')
    old_size = int.from_bytes(region[16:20], 'little')

    if name == 'rootfs':
        print(f'  Rootfs: {old_size} -> {len(new_rootfs)} bytes')

        # Update size
        region[16:20] = len(new_rootfs).to_bytes(4, 'little')

        # Update CRC32
        new_crc = zlib.crc32(new_rootfs) & 0xffffffff
        region[24:28] = new_crc.to_bytes(4, 'big')

        # Write updated region header
        data[offset:offset+64] = region

        # Rebuild image
        before = data[640:image_offset]
        after_start = image_offset + old_size
        after = data[after_start:]

        output = bytearray()
        output.extend(data[0:640])
        output.extend(before)
        output.extend(new_rootfs)
        output.extend(after)

        outpath = '$BUILD_DIR/83_IMAGE_CUSTOM'
        with open(outpath, 'wb') as f:
            f.write(output)

        print(f'  Output: {outpath} ({len(output)} bytes, {len(output)//1048576} MB)')
        break

    offset += 64
    image_offset += old_size
PYEOF
}

# --- Main ---
extract_rootfs
strip_cortana
disable_wireless
install_airplay
apply_overlay
patch_init_rc
patch_serviceport
update_hosts
repack_rootfs
rebuild_image

echo ""
echo "========================================="
echo "Build Complete!"
echo "========================================="
echo "Custom image: $BUILD_DIR/83_IMAGE_CUSTOM"
echo ""
echo "Next steps:"
echo "  1. Connect Invoke via USB in flash mode"
echo "  2. Run: sudo python3 PodiumFlashing/imager.py flash $BUILD_DIR/83_IMAGE_CUSTOM"
