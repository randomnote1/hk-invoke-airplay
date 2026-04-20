#!/bin/bash
# Flash a custom 83_IMAGE to the HK Invoke using PodiumFlashing tools.
#
# Prerequisites:
#   - HK Invoke connected via micro-USB
#   - Invoke in flash mode (hold reset + power, press back button 4x, LED ring yellow)
#   - PodiumFlashing repo cloned at ../PodiumFlashing (relative to project root)
#   - pexpect and Python 3 installed
#
# Usage:
#   sudo bash scripts/flash.sh [path-to-83_IMAGE]
#   If no path given, uses build/83_IMAGE_CUSTOM

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"

# Default image path
IMAGE_PATH="${1:-$BUILD_DIR/83_IMAGE_CUSTOM}"

# PodiumFlashing location
PODIUM_DIR="${PODIUM_DIR:-$(dirname "$PROJECT_DIR")/PodiumFlashing}"

if [ ! -f "$IMAGE_PATH" ]; then
    echo "Error: Image not found at $IMAGE_PATH"
    echo "Usage: $0 [path-to-83_IMAGE]"
    exit 1
fi

if [ ! -d "$PODIUM_DIR" ]; then
    echo "Error: PodiumFlashing not found at $PODIUM_DIR"
    echo "Set PODIUM_DIR environment variable or clone PodiumFlashing next to this project."
    exit 1
fi

echo "========================================="
echo "HK Invoke Flasher"
echo "========================================="
echo "Image: $IMAGE_PATH"
echo "Size: $(du -h "$IMAGE_PATH" | cut -f1)"
echo ""
echo "IMPORTANT: Make sure the Invoke is in flash mode!"
echo "  1. Unplug power from the Invoke"
echo "  2. Hold the reset button"
echo "  3. Plug in power (while still holding reset)"
echo "  4. Press the back button 4 times within 5 seconds"
echo "  5. The LED ring should turn YELLOW"
echo "  6. Connect micro-USB from Invoke to this PC"
echo ""
read -p "Is the Invoke in flash mode with LED ring yellow? [y/N] " confirm

if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborting. Put the Invoke in flash mode first."
    exit 0
fi

# Copy the image to PodiumFlashing's marvell_flash_tool directory
echo ">>> Copying image to flash tool..."
cp "$IMAGE_PATH" "$PODIUM_DIR/marvell_flash_tool/83_IMAGE"

# Run PodiumFlashing's flash command
echo ">>> Starting flash process..."
cd "$PODIUM_DIR"
python3 imager.py flash "marvell_flash_tool/83_IMAGE" -v

echo ""
echo "========================================="
echo "Flash complete!"
echo "========================================="
echo "Unplug USB, cycle power, and test AirPlay."
