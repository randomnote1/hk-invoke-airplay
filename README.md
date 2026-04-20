# HK Invoke AirPlay Speaker

Convert a bricked Harman Kardon Invoke smart speaker into a dedicated AirPlay 2 / Apple Music speaker.

## What This Does

The Harman Kardon Invoke (codename "Podium") was a Cortana-powered smart speaker that became essentially useless when Microsoft discontinued Cortana. This project repurposes the hardware as a high-quality AirPlay 2 speaker using [shairport-sync](https://github.com/mikebrady/shairport-sync).

### Features
- **AirPlay 2** — stream from Apple Music, Spotify, or any AirPlay source
- **Volume dial** — capacitive touch ring on top controls volume
- **Touch controls** — tap for play/pause, double-tap for next track
- **LED ring** — status feedback (network, playback, volume)
- **No WiFi/Bluetooth** — disabled for security; uses USB Ethernet instead
- **No microphones** — permanently disabled in software (optionally disconnect physically)

## Hardware

| Component | Details |
|---|---|
| Speaker | Harman Kardon Invoke (6132A-HKINVOKE) |
| SoC | Marvell Berlin (88DE3xxx), quad-core ARMv7 |
| RAM | 512MB LPDDR3 |
| Storage | 4GB eMMC |
| Audio | 3 woofers, 3 tweeters, 2 passive radiators, DSP |
| Network | USB Ethernet via micro-USB service port |
| Kernel | Linux 3.8.13-yocto-standard |

## How It Works

The stock Linux rootfs (SquashFS) is extracted, modified to replace the Cortana stack with shairport-sync and a custom control daemon, then reflashed using the Marvell USB boot tools from the [HKHacking](https://github.com/coggy9/HKHacking) project.

### Architecture
```
iPhone/Mac ──AirPlay 2──► USB NIC ──► Linux (shairport-sync) ──► ALSA DSP ──► 6 Speakers
                                          │
                              Touch Input ─┤── Volume control
                              MCU Interface ┤── LED ring feedback
                              Control Daemon ┘
```

## Prerequisites

- Harman Kardon Invoke speaker
- 19V DC power adapter (5.5×2.5mm barrel, center-positive, 2A+)
- Micro-USB cable
- USB OTG adapter (micro-USB male to USB-A female)
- USB Ethernet adapter (ASIX AX88179 or Realtek RTL8153 chipset)
- PC with WSL (Ubuntu) for flashing

## Project Structure

```
├── rootfs/              # Modified rootfs overlay files
│   ├── etc/
│   │   ├── init.rc      # Modified init (shairport-sync, control daemon)
│   │   ├── shairport-sync.conf
│   │   └── asound-product.conf  # ALSA config for AirPlay output
│   └── usr/
│       ├── bin/
│       │   ├── shairport-sync   # Cross-compiled AirPlay 2 daemon
│       │   ├── nqptp            # PTP timing daemon
│       │   └── invoke-ctl       # Control daemon (volume, touch, LEDs)
│       └── lib/
├── scripts/             # Build and flash scripts
│   ├── build-rootfs.sh  # Extract, modify, repack SquashFS
│   ├── cross-compile.sh # Cross-compile dependencies
│   └── flash.sh         # Flash modified image
├── src/
│   └── invoke-ctl/      # Control daemon source (C)
└── docs/
    └── firmware-analysis.md  # Detailed rootfs analysis notes
```

## Acknowledgments

- [coggy9/HKHacking](https://github.com/coggy9/HKHacking) — firmware dumps, ADB images, flashing tools
- [CaramelKat/PodiumFlashing](https://github.com/CaramelKat/PodiumFlashing) — image extract/rebuild tools
- [mikebrady/shairport-sync](https://github.com/mikebrady/shairport-sync) — AirPlay 2 audio player
- Harman Kardon — GPL kernel source disclosure

## License

MIT
