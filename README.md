# pve-sleep

Bash-based sleep and wake inspection and setup toolkit for Proxmox 8 on Debian 12 and Proxmox 9 on Debian 13.

## What it does

The toolkit detects and reports:

- CPU governors and powersave or performance modes
- GPU power controls
- lid switch, built-in display, external display, and battery presence
- physical ethernet and Wi-Fi adapters
- Wake-on-LAN, Wake-on-Wireless-LAN, USB wake, RTC wake, and supported sleep states
- systemd, logind, timer, and GRUB settings that affect sleep or wake behavior
- package requirements for battery support, wake support, Wi-Fi fallback, firmware, and CPU microcode

It can also:

- safely install missing packages in a single prompt after checking the Proxmox apt transaction
- enable Wake-on-LAN and Wake-on-Wireless-LAN where supported
- scan the top 5 visible Wi-Fi networks by signal strength and configure wpa-supplicant
- configure Wi-Fi as fallback when ethernet is lost and prefer ethernet again when it returns
- blank the local console and internal panel on lid-close events without putting the host to sleep
- monitor battery state and prepare a future sleep pathway without invoking host sleep automatically
- prepare running VMs and containers for a later sleep workflow with the safe-sleep helper

## Important network note

Wi-Fi can be used as a management failover path, but it cannot be bridged directly into a Proxmox Linux bridge unless you use a VPN or a routed design.

## Installed layout

Running the installer places the project in:

- /opt/pve-sleep
- /opt/pve-sleep/bin

The installer also replaces symlinks for the included udev and systemd files:

- /etc/udev/rules.d/99-pve-sleep-lid.rules
- /etc/systemd/system/console-blank.service
- /etc/systemd/system/pve-lid-handler.service
- /etc/systemd/system/pve-battery-monitor.service
- /etc/systemd/system/pve-network-failover.service

## Output

Each detection run writes:

- sleep-system.txt
- sleep-system.json

When package installation is requested, the toolkit also keeps:

- sleep-system-before.txt
- sleep-system-before.json
- sleep-system-after.txt
- sleep-system-after.json

## Install

### One-line GitHub install

```sh
curl -L https://github.com/Kryxan/pve-sleep/archive/refs/heads/main.tar.gz | tar xz -C /tmp/ && bash /tmp/pve-sleep-main/pvesleep-install.sh
```

### Local install from a checkout

Run as root:

```sh
./pvesleep-install.sh
```

This installs the toolkit into /opt/pve-sleep, stores the installer at /opt/pve-sleep/pvesleep-install.sh for later reuse, reloads the linked service and rule files, and automatically runs the detector.

## Usage

### Detect only

```sh
/opt/pve-sleep/pve-sleep-detect.sh
```

### Reinstall or change install options later

```sh
/opt/pve-sleep/pvesleep-install.sh
/opt/pve-sleep/pvesleep-install.sh --install-missing --enable-wake --configure-wifi
```

### Verify writable wake controls without permanent change

```sh
/opt/pve-sleep/pve-sleep-detect.sh --probe-write
```

### Detect, prompt once for all safe package installs, enable wake, and configure Wi-Fi fallback

```sh
/opt/pve-sleep/pve-sleep-detect.sh --install-missing --enable-wake --configure-wifi
```

This interactive flow will:

1. print the current support report
2. show a single list of needed packages and ask once whether to install them, defaulting to yes
3. re-run detection after installation and save before and after reports
4. show the top 5 Wi-Fi networks by signal strength and let you pick one or skip

### Uninstall

```sh
/opt/pve-sleep/pvesleep-install.sh --uninstall
```

This disables and removes the linked pve-sleep services and udev rule. For safety, custom hooks and unrelated system network configuration are left in place.

## Helper scripts

### safe-sleep

The safe-sleep helper does not put the host to sleep. It only prepares guests so you can integrate it into a later suspend workflow.

```sh
/opt/pve-sleep/bin/safe-sleep.sh prepare
/opt/pve-sleep/bin/safe-sleep.sh restore
/opt/pve-sleep/bin/safe-sleep.sh status
```

Behavior:

- VMs are suspended if possible
- containers are suspended if possible
- if suspend is not available, the guest is snapshotted and then shut down or stopped
- restore brings previously prepared guests back

### sleep.target integration example

If you later decide to wire this into a real host sleep workflow, one safe pattern is to call the helper before sleep and restore after wake.

Example pre-sleep service:

```ini
[Unit]
Description=Prepare Proxmox guests for host sleep
Before=sleep.target

[Service]
Type=oneshot
ExecStart=/opt/pve-sleep/bin/safe-sleep.sh prepare

[Install]
WantedBy=sleep.target
```

A matching post-wake restore step can call:

```sh
/opt/pve-sleep/bin/safe-sleep.sh restore
```

## Battery monitor

The battery monitor service only watches for low battery while AC power is absent and the battery is not charging. It does not force host sleep by default.

Instead it:

- logs the condition
- prepares guests by calling the safe-sleep helper when available
- creates a future hand-off path through an optional executable hook at:

```sh
/opt/pve-sleep/hooks/request-sleep.sh
```

If you later want to trigger an actual suspend action, place your own hook there.

## Console blanking and lid behavior

The included lid rule and handler are intended for screen-off behavior only.

- lid close blanks the backlight and consoles
- lid open restores the saved backlight values
- console blanking is managed by the console-blank service
- no host sleep action is performed here

## Notes

- Package installation is gated by the apt safety checks in the shared apt helper.
- The toolkit avoids dumping every interrupt and wake source and instead summarizes only the items relevant to sleep and wake troubleshooting.
- On a Proxmox node with active guests, host suspend still has operational risk even when guest preparation is available.
