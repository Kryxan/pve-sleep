#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# sleep-boot.sh — boot-time persistence for pve-sleep settings
#
# Applied on every boot via pve-sleep-boot.service:
# - CPU/GPU governors
# - WoL on Ethernet adapters
# - WoWLAN on WiFi adapters
# - USB wake on all devices
# - Network adapter power mode for wake support
# =============================================================================

BOOT_CONF="/etc/pve-sleep/boot.conf"
CPU_GOVERNOR="powersave"
GPU_DPM="auto"
USB_WAKE_MODE="all"

# Load overrides from config file
[[ -r "$BOOT_CONF" ]] && . "$BOOT_CONF"

log_boot() {
  echo "[sleep-boot] $*"
  command -v logger >/dev/null 2>&1 && logger -t pve-sleep-boot -- "$*" || true
}

# --- CPU governor ---
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [[ -w "$gov" ]] && echo "$CPU_GOVERNOR" > "$gov" 2>/dev/null || true
done
log_boot "CPU governor set to $CPU_GOVERNOR"

# --- GPU power mode (no driver install, runtime tuning only) ---
for dpm in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
  [[ -w "$dpm" ]] && echo "$GPU_DPM" > "$dpm" 2>/dev/null || true
done

# --- WoL on all physical Ethernet adapters ---
for path in /sys/class/net/*; do
  iface="$(basename "$path")"
  [[ -d "$path/wireless" ]] && continue
  [[ -e "$path/device" ]] || continue
  case "$iface" in lo|vmbr*|veth*|tap*|fwln*|fwbr*|fwpr*|docker*|virbr*|br-*|vnet*) continue ;; esac
  if command -v ethtool >/dev/null 2>&1; then
    ethtool -s "$iface" wol g 2>/dev/null && log_boot "WoL enabled on $iface" || true
  fi
done

# --- WoWLAN on all WiFi adapters ---
for path in /sys/class/net/*; do
  iface="$(basename "$path")"
  [[ -d "$path/wireless" ]] || continue
  [[ -e "$path/device" ]] || continue
  if command -v iw >/dev/null 2>&1; then
    phy="$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/ {print "phy"$2; exit}')"
    [[ -n "$phy" ]] && iw phy "$phy" wowlan enable any 2>/dev/null && \
      log_boot "WoWLAN enabled on $iface" || true
  fi
done

# --- USB wake ---
case "$USB_WAKE_MODE" in
  all)
    count=0
    for wakeup in /sys/bus/usb/devices/*/power/wakeup; do
      [[ -w "$wakeup" ]] && echo "enabled" > "$wakeup" 2>/dev/null && count=$((count + 1))
    done
    log_boot "USB wake enabled on $count device(s)"
    ;;
  none)
    log_boot "USB wake disabled by config"
    ;;
  *)
    # File with list of specific device IDs
    if [[ -r "$USB_WAKE_MODE" ]]; then
      while IFS= read -r dev; do
        [[ -w "/sys/bus/usb/devices/$dev/power/wakeup" ]] && \
          echo "enabled" > "/sys/bus/usb/devices/$dev/power/wakeup" 2>/dev/null || true
      done < "$USB_WAKE_MODE"
      log_boot "USB wake enabled for devices in $USB_WAKE_MODE"
    fi
    ;;
esac

# --- Network adapter power management for wake support ---
for ctrl in /sys/class/net/*/device/power/control; do
  [[ -w "$ctrl" ]] && echo "on" > "$ctrl" 2>/dev/null || true
done
log_boot "Network adapter power mode set to 'on' for wake"

log_boot "Boot configuration complete"
