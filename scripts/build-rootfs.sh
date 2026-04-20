#!/bin/bash
# Build a modified rootfs image for the HK Invoke AirPlay speaker.
#
# This script:
#   1. Extracts the ADB-enabled rootfs from 83_IMAGE
#   2. Removes Cortana/Libre services
#   3. Installs shairport-sync, nqptp, invoke-ctl
#   4. Modifies init.rc for AirPlay boot
#   5. Disables WiFi/BT/mic module loading
#   6. Repacks into a flashable 83_IMAGE
#
# Prerequisites:
#   - Run cross-compile.sh first to build binaries
#   - squashfs-tools installed (sudo apt install squashfs-tools)
#   - Python 3 for PodiumFlashing imager
#
# Usage:
#   sudo bash scripts/build-rootfs.sh <path-to-83_IMAGE_ADB>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
STAGING_DIR="$BUILD_DIR/staging"
ROOTFS_DIR="$BUILD_DIR/rootfs"
OVERLAY_DIR="$PROJECT_DIR/rootfs"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <path-to-83_IMAGE_ADB>"
    echo "  The ADB-enabled 83_IMAGE from HKHacking releases."
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
    
    # Use Python to extract the rootfs region
    python3 -c "
import sys
data = open('$IMAGE_PATH', 'rb').read()

# Parse region table
offset = 64
image_offset = 640
for i in range(9):
    region = data[offset:offset+64]
    name = region[0:16].decode('utf-8').rstrip('\x00')
    size = int.from_bytes(region[16:20], 'little')
    
    if name == 'rootfs':
        print(f'Found rootfs at offset {image_offset}, size {size} bytes')
        with open('$BUILD_DIR/rootfs.bin', 'wb') as f:
            f.write(data[image_offset:image_offset+size])
        print('Extracted rootfs.bin')
        break
    
    offset += 64
    image_offset += size
"
    
    # Unsquash the rootfs
    rm -rf "$ROOTFS_DIR"
    unsquashfs -f -no-xattrs -d "$ROOTFS_DIR" "$BUILD_DIR/rootfs.bin"
    echo "Rootfs extracted to $ROOTFS_DIR"
}

# --- Step 2: Remove Cortana/Libre services ---
strip_cortana() {
    echo ">>> Removing Cortana and Libre services..."
    
    # Remove the main Cortana orchestrator
    rm -f "$ROOTFS_DIR/usr/bin/system-manager"
    rm -rf "$ROOTFS_DIR/etc/podium"
    rm -f "$ROOTFS_DIR/usr/bin/run-podium.sh"
    
    # Remove Libre service binaries (keep system essentials)
    local remove_bins=(
        LibreManager yani_service luci_service MessageBoxHandler
        LibreEnv firstboot certgen LUCI_local servicemanager
        mediaserver BluetoothSystem spotify
        copy.sh copy_eng.sh
        startDDMSAP.sh startHostAP.sh start_softap.sh start_webserver.sh
    )
    for bin in "${remove_bins[@]}"; do
        rm -f "$ROOTFS_DIR/system/bin/$bin"
    done
    
    # Remove WiFi supplicant config (not needed)
    rm -f "$ROOTFS_DIR/sbin/wpa_supplicant_setup.sh"
    
    echo "Cortana services removed."
}

# --- Step 3: Disable WiFi/BT/mic kernel modules ---
disable_wireless() {
    echo ">>> Disabling WiFi/BT kernel modules..."
    
    local modules_dir="$ROOTFS_DIR/lib/modules/3.8.13-yocto-standard"
    
    # Remove WiFi modules
    rm -rf "$modules_dir/kernel/arch/arm/mach-berlin/modules/wlan_sd8887"
    rm -rf "$modules_dir/wlan_sd8887"
    
    # Remove Bluetooth modules
    rm -f "$modules_dir/kernel/drivers/bluetooth/btmrvl.ko"
    rm -f "$modules_dir/kernel/arch/arm/mach-berlin/modules/bt_sd8887/bt8xxx.ko"
    rm -rf "$modules_dir/kernel/arch/arm/mach-berlin/modules/bt_sd8887"
    
    # Remove Bluetooth config directory
    rm -rf "$ROOTFS_DIR/bluetooth"
    
    echo "WiFi/BT modules removed."
}

# --- Step 4: Install shairport-sync and dependencies ---
install_airplay() {
    echo ">>> Installing shairport-sync and dependencies..."
    
    # Copy cross-compiled binaries
    if [ -f "$STAGING_DIR/bin/shairport-sync" ]; then
        cp "$STAGING_DIR/bin/shairport-sync" "$ROOTFS_DIR/usr/bin/"
        chmod 755 "$ROOTFS_DIR/usr/bin/shairport-sync"
    else
        echo "WARNING: shairport-sync not found in staging. Run cross-compile.sh first."
    fi
    
    if [ -f "$STAGING_DIR/bin/nqptp" ]; then
        cp "$STAGING_DIR/bin/nqptp" "$ROOTFS_DIR/usr/bin/"
        chmod 755 "$ROOTFS_DIR/usr/bin/nqptp"
    else
        echo "WARNING: nqptp not found in staging. Run cross-compile.sh first."
    fi
    
    if [ -f "$STAGING_DIR/bin/invoke-ctl" ]; then
        cp "$STAGING_DIR/bin/invoke-ctl" "$ROOTFS_DIR/usr/bin/"
        chmod 755 "$ROOTFS_DIR/usr/bin/invoke-ctl"
    else
        echo "WARNING: invoke-ctl not found in staging. Run cross-compile.sh first."
    fi
    
    # Copy any required shared libraries
    if [ -d "$STAGING_DIR/lib" ]; then
        cp -a "$STAGING_DIR/lib/"*.so* "$ROOTFS_DIR/usr/lib/" 2>/dev/null || true
    fi
    
    echo "AirPlay binaries installed."
}

# --- Step 5: Apply rootfs overlay ---
apply_overlay() {
    echo ">>> Applying rootfs overlay..."
    
    if [ -d "$OVERLAY_DIR" ]; then
        cp -a "$OVERLAY_DIR/"* "$ROOTFS_DIR/" 2>/dev/null || true
        echo "Overlay applied."
    else
        echo "No overlay directory found, skipping."
    fi
}

# --- Step 6: Modify init.rc ---
patch_init_rc() {
    echo ">>> Patching init.rc..."
    
    # The overlay should contain our modified init.rc
    # If not, patch the existing one
    if [ ! -f "$OVERLAY_DIR/init.rc" ]; then
        echo "WARNING: No overlay init.rc found. Manual patching needed."
        return
    fi
    
    echo "init.rc patched via overlay."
}

# --- Step 7: Update hosts file ---
update_hosts() {
    echo ">>> Updating hosts file..."
    
    cat > "$ROOTFS_DIR/etc/hosts" << 'EOF'
127.0.0.1 localhost localhost.localdomain

# IPv6
::1 localhost ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

# Block OTA updates
127.0.0.1 redbend.com
127.0.0.1 saf1.redbend.com
127.0.0.1 neptune.redbend.com
127.0.0.1 harman-podium.redbend.com
EOF
    
    echo "Hosts file updated."
}

# --- Step 8: Repack rootfs ---
repack_rootfs() {
    echo ">>> Repacking rootfs as SquashFS..."
    
    rm -f "$BUILD_DIR/rootfs_new.bin"
    mksquashfs "$ROOTFS_DIR" "$BUILD_DIR/rootfs_new.bin" \
        -b 131072 \
        -comp gzip \
        -noappend \
        -no-xattrs
    
    local new_size=$(stat -c%s "$BUILD_DIR/rootfs_new.bin")
    local max_size=$((720 * 131072))  # 720 blocks × 128KB = 90 MB
    
    echo "New rootfs: $new_size bytes ($((new_size / 1048576)) MB)"
    echo "Max allowed: $max_size bytes ($((max_size / 1048576)) MB)"
    
    if [ "$new_size" -gt "$max_size" ]; then
        echo "ERROR: Rootfs exceeds partition limit!"
        exit 1
    fi
    
    echo "Rootfs repacked."
}

# --- Step 9: Rebuild 83_IMAGE ---
rebuild_image() {
    echo ">>> Rebuilding 83_IMAGE..."
    
    python3 -c "
import zlib
import sys

data = bytearray(open('$IMAGE_PATH', 'rb').read())
new_rootfs = open('$BUILD_DIR/rootfs_new.bin', 'rb').read()

# Parse region table to find rootfs offset and update
offset = 64
image_offset = 640

for i in range(9):
    region = bytearray(data[offset:offset+64])
    name = region[0:16].decode('utf-8').rstrip('\x00')
    old_size = int.from_bytes(region[16:20], 'little')
    
    if name == 'rootfs':
        print(f'Rootfs at image offset {image_offset}')
        print(f'Old size: {old_size}, New size: {len(new_rootfs)}')
        
        # Update size in region header
        region[16:20] = len(new_rootfs).to_bytes(4, 'little')
        
        # Update CRC32
        new_crc = zlib.crc32(new_rootfs).to_bytes(4, 'big')
        region[24:28] = new_crc
        
        # Write updated region header
        data[offset:offset+64] = region
        
        # Rebuild: header + regions before rootfs + new rootfs + regions after rootfs
        before_rootfs = data[640:image_offset]
        after_rootfs_start = image_offset + old_size
        after_rootfs = data[after_rootfs_start:]
        
        output = bytearray()
        output.extend(data[0:640])  # header + region table
        output.extend(before_rootfs)
        output.extend(new_rootfs)
        output.extend(after_rootfs)
        
        with open('$BUILD_DIR/83_IMAGE_CUSTOM', 'wb') as f:
            f.write(output)
        
        print(f'Built: $BUILD_DIR/83_IMAGE_CUSTOM ({len(output)} bytes)')
        break
    
    offset += 64
    image_offset += old_size
"
    
    echo "83_IMAGE rebuilt."
}

# --- Main ---
extract_rootfs
strip_cortana
disable_wireless
install_airplay
apply_overlay
patch_init_rc
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
echo "  1. Put Invoke in flash mode (hold reset + power, press back button 4x)"
echo "  2. Run: sudo bash scripts/flash.sh $BUILD_DIR/83_IMAGE_CUSTOM"
