# Detect HK Invoke on USB
# Run this after plugging in the speaker via micro-USB service port
#
# The Invoke can appear as:
#   VID:PID 1286:8174  — Flash/DFU mode (Marvell USB boot)
#   VID:PID 18D1:0D02  — ADB mode (Android USB gadget)
#   VID:PID 18D1:????  — RNDIS/Ethernet gadget mode

$adb = "C:\Users\dareist\source\repos\platform-tools\adb.exe"

Write-Host "=== HK Invoke USB Detection ===" -ForegroundColor Cyan
Write-Host ""

# Check for Marvell flash mode device
$flashDev = Get-PnpDevice -Status OK -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match "VID_1286&PID_8174" }

if ($flashDev) {
    Write-Host "[FLASH MODE] Invoke detected in Marvell USB boot mode" -ForegroundColor Yellow
    Write-Host "  Ready to flash firmware image"
    Write-Host "  Use PodiumFlashing imager.py to flash"
    exit 0
}

# Check for ADB device
$adbDev = Get-PnpDevice -Status OK -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match "VID_18D1" }

if ($adbDev) {
    Write-Host "[ADB MODE] Invoke detected as Android USB device" -ForegroundColor Green
    & $adb devices
    Write-Host ""
    Write-Host "  Run probe script: scripts\probe-device.sh (via WSL)"
    exit 0
}

# Check for any new USB devices
$allUsb = Get-PnpDevice -Class USB -Status OK |
    Where-Object { $_.FriendlyName -notmatch "Hub|Controller|Root" } |
    Select-Object InstanceId, FriendlyName

Write-Host "USB devices found:" -ForegroundColor White
$allUsb | Format-Table -AutoSize

Write-Host ""
Write-Host "If the Invoke is connected but not detected:" -ForegroundColor Yellow
Write-Host "  1. Ensure power cable is plugged in (19V barrel jack)"
Write-Host "  2. Try a different USB cable (must support data, not charge-only)"
Write-Host "  3. To enter flash mode: hold volume dial down while powering on"
Write-Host "  4. Check Device Manager for unknown/errored devices"
