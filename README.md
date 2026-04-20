# pve-sleep

Modular sleep, wake, and power management toolkit for Proxmox 8 (Debian 12) and Proxmox 9 (Debian 13).

This is based on work previously written by me but never completed. It became too large and broken to easily manage and fix. The end goal is proxmox node power management so heavy work (such as AI LLM and image generation) can trigger other hosts to wake up to assist as needed.I am also looking into steam game mode and android game containtainers that can trigger host wakeup when needed.  

Eventaully, plan is for full configuration for intelligent wake and sleep functions to be added so a yet to be fully envisioned control system can be aware of other proxmox nodes and the need to trigger wakeup.  

## What it does

### Detection

- CPU model, governor, available governors, microcode version
- GPU vendor, driver, DPM power mode
- Lid switch, built-in display, external displays, battery presence and capacity
- Physical Ethernet and Wi-Fi adapters (excludes Proxmox bridges, veth, tap, etc.)
- Wake-on-LAN support and current mode per Ethernet adapter
- Wake-on-Wireless-LAN support per WiFi adapter
- USB devices and wake capability
- Supported sleep states (S3, s2idle, etc.), mem_sleep config, RTC wake
- systemd logind HandleLidSwitch* settings
- Active systemd timers that may interfere with sleep
- GRUB and kernel sleep-related parameters
- Package recommendations (CPU microcode, WiFi firmware, ethtool, iw, wpasupplicant)

### Configuration

- Install missing packages with apt safety checks (blocks Proxmox-breaking operations)
- Enable WoL on Ethernet, WoWLAN on WiFi adapters
- Enable USB wake on all devices
- Set CPU governor (powersave) and GPU DPM (auto)
- Configure WiFi as metric-200 failover with wpa_supplicant
- Write /etc/network/interfaces.d/wifi-failover and source line
- Blank console on lid close (no sleep)
- Configure sleep modes (only S3/s2idle, only on low battery)
- Boot persistence via /etc/pve-sleep/boot.conf + systemd service

### Safe Sleep

- Suspend or snapshot+stop running VMs and containers before host sleep
- Restore guests after wake
- Verify WoL/WoWLAN is active before allowing sleep
- Verify compatible sleep mode (S3 or s2idle) before sleeping
- Integrated with sleep.target via pve-safe-sleep.service
- Battery monitor triggers safe-sleep on low battery (no AC, not charging)

## Architecture

```text
bin/
  lib/
    common.sh      # Shared utilities, logging, json helpers
    detect.sh      # All hardware/system detection functions
    network.sh     # Interface helpers, WiFi, WoL, WoWLAN, interface files
    packages.sh    # Apt management, package recommendations, safety checks
    configure.sh   # Configuration actions (packages, wake, wifi, governors, sleep)
    report.sh      # TXT and JSON report rendering
  pve-sleep-detect.sh       # Main orchestrator (10-phase flow)
  safe-sleep.sh             # Guest preparation, restore, and host sleep trigger
  sleep-boot.sh             # Boot-time persistence (governors, WoL, USB wake)
  battery-monitor.sh        # Battery watch, triggers safe-sleep on low battery
  network-failover-monitor.sh  # WiFi failover monitor
  lid-handler.sh            # Lid close/open handler (blank only)
  console-blank.sh          # Console blanking service script
  aptfunctions.sh           # Backward-compat shim -> lib/packages.sh
  networkwake.sh            # Backward-compat shim -> lib/network.sh
  pve-sleep-boot.service    # Systemd: apply boot config
  pve-safe-sleep.service    # Systemd: sleep.target integration
  pve-battery-monitor.service
  pve-network-failover.service
  pve-lid-handler.service
  console-blank.service
  99-lid.rules              # Udev rule for lid events
pvesleep-install.sh         # Installer / uninstaller
```

## Network design

WiFi is configured as a management failover path with metric-based routing:

- **Ethernet**: metric 100 (primary, preferred when cable is connected)
- **WiFi**: metric 200 (failover, always connected via wpa_supplicant)
- Both interfaces get DHCP leases; Linux routing uses the lower metric
- WiFi **cannot** be bridged directly into a Proxmox Linux bridge (requires VPN/routed design)
- The toolkit writes `/etc/network/interfaces.d/wifi-failover` and adds a `source` line
- Existing bridge configs (vmbr*) are never modified

## Install

### One-line GitHub install

```sh
curl -L https://github.com/Kryxan/pve-sleep/archive/refs/heads/main.tar.gz \
  | tar xz -C /tmp/ && bash /tmp/pve-sleep-main/pvesleep-install.sh
```

### Local install from checkout

```sh
./pvesleep-install.sh
```

This installs into `/opt/pve-sleep`, creates symlinks for systemd units and udev rules, adds convenience symlinks in `/usr/local/bin/`, and runs the detector/configurator.

## Usage

### Interactive (prompts for all features)

```sh
/opt/pve-sleep/pve-sleep-detect.sh
```

### Non-interactive (all features enabled)

```sh
/opt/pve-sleep/pve-sleep-detect.sh \
  --install-missing --enable-wake --configure-wifi "SSID" "PASSWORD"
```

### Non-interactive (all features disabled)

```sh
/opt/pve-sleep/pve-sleep-detect.sh \
  --no-install-missing --no-enable-wake --no-configure-wifi
```

### Safe sleep (guest-aware suspend)

```sh
# Prepare guests, verify wake, suspend, restore on wake
safe-sleep.sh sleep

# Or step by step:
safe-sleep.sh prepare
safe-sleep.sh restore
safe-sleep.sh status
```

### Reinstall or update

```sh
/opt/pve-sleep/pvesleep-install.sh
```

### Uninstall

```sh
/opt/pve-sleep/pvesleep-install.sh --uninstall
```

Custom hooks, `/etc/pve-sleep/`, and WiFi configuration are left untouched.

## Output

Each detection run writes:

- `sleep-system.txt` — human-readable report
- `sleep-system.json` — machine-readable report

When package installation is requested, before/after snapshots are saved:

- `sleep-system-before.{txt,json}`
- `sleep-system-after.{txt,json}`

## Boot persistence

After running the configurator, settings are saved to `/etc/pve-sleep/boot.conf` and reapplied on every boot by `pve-sleep-boot.service`:

- CPU governor
- GPU DPM power mode
- WoL on Ethernet adapters
- WoWLAN on WiFi adapters
- USB wake on all devices
- Network adapter power mode set to "on" for wake support

## Apt safety checks

Package installation is gated by safety checks that **block** any apt transaction that would:

- Remove Proxmox core packages (proxmox-ve, pve-manager, pve-kernel-*, etc.)
- Install Debian kernel packages (linux-image-*, linux-headers-*)
- Install initramfs-tools (Proxmox uses dracut)
- Remove or replace pve-firmware or dracut

## Services

| Service | Purpose |
| --- | --- |
| `pve-sleep-boot.service` | Apply boot.conf settings on startup |
| `pve-safe-sleep.service` | Prepare guests before sleep.target, restore after wake |
| `pve-battery-monitor.service` | Watch battery, trigger safe-sleep on low battery |
| `pve-network-failover.service` | Monitor WiFi failover status |
| `pve-lid-handler.service` | Handle lid close/open (blank only, no sleep) |
| `console-blank.service` | Blank console and backlight |

## Notes

- Sleep is **only** triggered on low battery when on battery power
- Sleep requires active WoL or WoWLAN and a compatible sleep mode (S3 or s2idle)
- The toolkit never auto-suspends; suspension is always gated by safety checks
- WiFi firmware packages are skipped if `pve-firmware` is already installed
- GPU configuration is runtime DPM tuning only; no driver installation
