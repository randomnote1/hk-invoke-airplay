#!/bin/bash
# Probe HK Invoke hardware via ADB
# Run after ADB connection is established
#
# Usage (from WSL):
#   bash /mnt/c/Users/dareist/source/repos/hk-invoke-airplay/scripts/probe-device.sh

set -euo pipefail

ADB=adb

echo "========================================="
echo "HK Invoke Hardware Probe"
echo "========================================="

# Verify ADB connection
echo ""
echo ">>> Checking ADB connection..."
$ADB wait-for-device
SERIAL=$($ADB get-serialno 2>/dev/null || echo "unknown")
echo "  Connected: $SERIAL"

echo ""
echo ">>> System info..."
$ADB shell "uname -a"
$ADB shell "cat /proc/version"

echo ""
echo ">>> CPU info..."
$ADB shell "cat /proc/cpuinfo" | head -20

echo ""
echo ">>> Memory..."
$ADB shell "free -m 2>/dev/null || cat /proc/meminfo | head -5"

echo ""
echo ">>> Storage..."
$ADB shell "df -h 2>/dev/null || df"

echo ""
echo "========================================="
echo "ALSA Audio Devices"
echo "========================================="
echo ">>> Sound cards..."
$ADB shell "cat /proc/asound/cards"

echo ""
echo ">>> PCM devices..."
$ADB shell "cat /proc/asound/pcm"

echo ""
echo ">>> Mixer controls (card 0)..."
$ADB shell "tinymix -a 2>/dev/null || echo 'tinymix not available'"

echo ""
echo ">>> ALSA config..."
$ADB shell "cat /etc/asound.conf 2>/dev/null || echo 'no asound.conf'"

echo ""
echo "========================================="
echo "USB Subsystem"
echo "========================================="
echo ">>> USB devices..."
$ADB shell "lsusb 2>/dev/null || echo 'no lsusb'"

echo ""
echo ">>> USB gadget config..."
$ADB shell "cat /sys/class/android_usb/android0/functions 2>/dev/null || echo 'no android_usb'"
$ADB shell "cat /sys/class/android_usb/android0/enable 2>/dev/null || echo ''"

echo ""
echo ">>> USB OTG / host mode..."
$ADB shell "ls /sys/bus/usb/drivers/ 2>/dev/null || echo 'no USB drivers listed'"
$ADB shell "cat /sys/kernel/debug/usb/devices 2>/dev/null | head -30 || echo 'no debug info'"
$ADB shell "lsmod 2>/dev/null | grep -i 'ehci\|usb\|otg\|gadget' || echo 'no USB modules loaded'"

echo ""
echo ">>> Network interfaces..."
$ADB shell "ifconfig -a 2>/dev/null || ip addr"

echo ""
echo "========================================="
echo "Input Devices (dial, touch, buttons)"
echo "========================================="
echo ">>> Input devices..."
$ADB shell "cat /proc/bus/input/devices"

echo ""
echo ">>> Input event nodes..."
$ADB shell "ls -la /dev/input/"

echo ""
echo "========================================="
echo "Kernel Modules"
echo "========================================="
$ADB shell "lsmod 2>/dev/null || cat /proc/modules"

echo ""
echo "========================================="
echo "Running Services"
echo "========================================="
$ADB shell "ps 2>/dev/null | grep -v '^\[' | head -40 || echo 'ps not available'"

echo ""
echo "========================================="
echo "GPIO / MCU Interface"
echo "========================================="
echo ">>> MCU interface..."
$ADB shell "ls -la /dev/mcu* 2>/dev/null || echo 'no /dev/mcu devices'"
$ADB shell "which mcu-interface 2>/dev/null && echo 'mcu-interface found' || echo 'no mcu-interface'"

echo ""
echo ">>> LED control..."
$ADB shell "ls /sys/class/leds/ 2>/dev/null || echo 'no LED sysfs'"

echo ""
echo "========================================="
echo "Probe Complete"
echo "========================================="
echo ""
echo "Next steps:"
echo "  1. Review ALSA output — confirm 'music' PCM device"
echo "  2. Review input devices — identify dial and touch event nodes"
echo "  3. Check USB OTG — can we switch to host mode?"
echo "  4. Run: adb shell getevent -l  (then rotate dial, tap surface)"
