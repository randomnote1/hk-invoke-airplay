# HK Invoke Firmware Analysis

Detailed analysis of the stock and ADB-enabled firmware images for the Harman Kardon Invoke (codename "Podium" / "chickentikka").

## Image Format

The 83_IMAGE firmware file uses a Marvell proprietary format:
- **Magic**: `F1 A3 AD D2`
- **Header**: 64 bytes (magic + metadata + region count)
- **Region table**: 9 × 64-byte entries
- **Image data**: concatenated region payloads
- **Footer**: ~304 KB

## Partition Layout

| Region | Size | CRC32 (Stock) | CRC32 (ADB) | Purpose |
|---|---|---|---|---|
| block0 | 128 KB | 6ED047D5 | 6ED047D5 | MBR/partition table |
| pre-bootloader | 128 KB | C94813C6 | C94813C6 | Early boot stage |
| post-bootloader | 256 KB | C89C04BC | C89C04BC | U-Boot |
| tz_en | 1.12 MB | BA5E424B | BA5E424B | TrustZone |
| bootimgs | 8.25 MB | D0F8CCD1 | D0F8CCD1 | Kernel + DTB (slot A) |
| bootimgs_B | 8.25 MB | D0F8CCD1 | D0F8CCD1 | Kernel + DTB (slot B) |
| **rootfs** | **77.65 MB** | **3199FB43** | **4FEE721E** | **SquashFS rootfs** |
| app | 1.04 MB | EBD0E95A | EBD0E95A | Application data |
| bsl | 2.59 MB | 585AE984 | 585AE984 | Bootloader stage |

**Only the rootfs differs** between stock and ADB-enabled images. All boot/kernel partitions are identical.

## Kernel

- **Version**: 3.8.13-yocto-standard
- **Architecture**: ARM EABI5 (ARMv7, hard-float)
- **Config**: SMP preempt, module unload
- **SoC**: Marvell Berlin (mach-berlin)
- **Board**: chickentikka (variants b1, b2, b3)

### Kernel Modules

| Module | Path | Purpose | Load? |
|---|---|---|---|
| `touchfilekmod.ko` | extra/ | Capacitive touch controller | ✅ Yes |
| `ehci-platform.ko` | kernel/drivers/usb/host/ | USB host controller | ✅ Yes (for USB NIC) |
| `mlan.ko` | mach-berlin/modules/wlan_sd8887/ | Marvell WiFi driver | ❌ Disable |
| `sd8xxx.ko` | mach-berlin/modules/wlan_sd8887/ | Marvell WiFi SDIO | ❌ Disable |
| `btmrvl.ko` | kernel/drivers/bluetooth/ | Marvell Bluetooth core | ❌ Disable |
| `bt8xxx.ko` | mach-berlin/modules/bt_sd8887/ | Marvell BT SDIO | ❌ Disable |

## Init System

Android-style `init` binary with `init.rc` configuration. Not systemd, not sysvinit.

### Boot Sequence
1. `ueventd` — device node creation
2. `mount_partition.sh` — mount data partitions
3. `load-kmod.sh` — loads `touchfilekmod` module
4. `firewall` — iptables rules
5. `mdnsd` — mDNS service
6. `adbd` / `sshd` — debug access
7. `alsa-init.sh` — initialize ALSA soft volumes
8. `startup_ls6` → `startup.sh` — Libre services (LibreManager, yani_service, etc.)
9. `podium` → `run-podium.sh` → `system-manager` — Cortana orchestrator
10. `serviceport` → `serviceport.sh` — USB Ethernet (eth0 @ 172.20.20.20)

### Key Services

| Service | Binary | Purpose | Keep? |
|---|---|---|---|
| `ueventd` | /sbin/ueventd | Device nodes | ✅ |
| `firewall` | firewall.sh | iptables | ✅ Modify |
| `mdnsd` | /bin/mdnsd | mDNS discovery | ✅ (or replace with avahi) |
| `adbd` | /sbin/adbd | ADB debug | ✅ Keep for maintenance |
| `sshd` | dropbear | SSH access | ✅ |
| `serviceport` | serviceport.sh | USB Ethernet | ✅ Modify for DHCP |
| `podium` | system-manager | **Cortana** | ❌ Remove |
| `startup_ls6` | startup.sh | Libre services | ❌ Remove (runs Cortana deps) |
| `dhcpcd` | dhcpcd | DHCP client | ✅ |
| `wpa_supplicant` | wpa_supplicant | WiFi | ❌ Remove |
| `console` | login | Root console | ✅ |
| `init_complete` | init_modules.sh | Module init | ❌ Remove (loads Cortana bins) |

## Audio Architecture

### ALSA Cards
- **Card 0**: ALSA Loopback device (internal audio routing)
- **Card 1**: DSP hardware (actual speakers)

### DSP Hardware (Card 1)
- Sample rate: 48000 Hz
- Format: S32_LE (32-bit signed little-endian)
- Channels: 2
- Interface: I2S to DSP processor

### ALSA PCM Devices (from asound-product.conf)

```
pcm.dsp          → hw:1 (raw DSP output)
pcm.dsp_dsnoop   → dsnoop on dsp (shared capture)
pcm.dsp_mic      → softvol on dsp_dsnoop (mic with software volume)
pcm.music        → softvol "music" → dmix → dsp
pcm.system       → softvol "system" → dmix → dsp
pcm.timer        → softvol "timer" → dmix → dsp
pcm.voice        → softvol "voice" → ladspa mbeq → dmix → dsp
pcm.call         → softvol "call" → dmix → dsp
pcm.default      → playback: hw:Loopback,0,5 / capture: mic
```

**shairport-sync output target**: `music` PCM device

### Volume Control
ALSA mixer controls on card 0:
- `music` — music playback volume (shairport-sync target)
- `system` — system sounds
- `mic` — microphone gain (disable this)

## USB Service Port

### Current Behavior
- `serviceport.sh` sets `eth0` to static IP `172.20.20.20`
- In ADB mode, `android_usb` gadget configured with ADB function
- USB VID:PID in flash mode: `1286:8174`

### For AirPlay Use
Two options:
1. **USB Gadget Ethernet** (RNDIS/CDC ECM) — requires bridge device
2. **USB Host Mode** — load `ehci-platform.ko`, plug in USB NIC

## Physical Controls

### Touch Controller
- Module: `touchfilekmod.ko` (custom, GPL licensed)
- Creates input events under `/dev/input/`

### MCU Interface
- Binary: `/usr/bin/mcu-interface`
- Listens on `127.0.0.1:9999`
- Controls LED ring, reads hardware button state

## Files Modified by ADB Image (vs Stock)
- `/etc/hosts` — OTA blocker entries (redbend.com → 127.0.0.1)
- `/init.rc` — enabled ADB, USB gadget config
- `/default.prop` — `ro.secure=0`, `persist.sys.usb.config=adb`
- Boot sound replaced
