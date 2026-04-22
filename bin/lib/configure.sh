#!/usr/bin/env bash
# =============================================================================
# pve-sleep: configure.sh — system configuration actions
# =============================================================================
set -u

# ---------------------------------------------------------------------------
# Package installation step
# ---------------------------------------------------------------------------

configure_packages_step() {
  local mode="$1"  # 0=skip, 1=prompt, 2=auto

  [[ -v NEEDED_PACKAGE_NAMES && ${#NEEDED_PACKAGE_NAMES[@]} -gt 0 ]] || { log "No additional packages needed."; return 0; }

  case "$mode" in
    0) log "Package installation skipped (--no-install-missing)."; return 0 ;;
    2)
      auto_install_packages "${NEEDED_PACKAGE_NAMES[@]}"
      return $?
      ;;
    1)
      prompt_and_install_packages "${NEEDED_PACKAGE_NAMES[@]}"
      return $?
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Wake features (WoL, WoWLAN, USB wake, network power modes)
# ---------------------------------------------------------------------------

configure_wake_step() {
  local mode="$1"  # 0=skip, 1=prompt, 2=auto

  case "$mode" in
    0) log "Wake configuration skipped (--no-enable-wake)."; return 0 ;;
    2) ;;  # proceed
    1)
      prompt_yn "Enable Wake-on-LAN, WoWLAN, and USB wake?" || {
        log "Wake configuration skipped by user."
        return 0
      }
      ;;
  esac

  # Enable WoL on all Ethernet adapters
  local iface
  for iface in $(nw_list_physical_ifaces); do
    if ! nw_is_wifi_iface "$iface"; then
      nw_enable_wol "$iface" && log "Enabled WoL on $iface" || true
    fi
  done

  # Enable WoWLAN on all WiFi adapters
  for iface in $(nw_list_physical_ifaces); do
    if nw_is_wifi_iface "$iface"; then
      nw_enable_wowlan "$iface" && log "Enabled WoWLAN on $iface" || true
    fi
  done

  # Enable USB wake on all capable devices
  nw_enable_usb_wake_all || true

  # Ensure network adapter power modes allow wake
  nw_set_network_power_for_wake
  log "Network adapter power modes set to 'on' for wake support."
}

# ---------------------------------------------------------------------------
# WiFi failover configuration
# ---------------------------------------------------------------------------

configure_wifi_step() {
  local mode="$1"  # 0=skip, 1=prompt, 2=auto
  local ssid="$2" pass="$3"

  local wifi_iface eth_iface
  wifi_iface="$(nw_first_wifi_iface 2>/dev/null || true)"
  eth_iface="$(nw_first_ethernet_iface 2>/dev/null || true)"

  case "$mode" in
    0) log "WiFi configuration skipped (--no-configure-wifi)."; return 0 ;;
    2)
      # Non-interactive with provided SSID and password
      if [[ -z "$wifi_iface" ]]; then
        warn "No Wi-Fi interface detected — cannot configure Wi-Fi failover."
        return 0
      fi
      ;;
    1)
      # Interactive
      if [[ -z "$wifi_iface" ]]; then
        warn "No Wi-Fi interface detected — skipping Wi-Fi configuration."
        return 0
      fi
      prompt_yn "Configure Wi-Fi for failover?" || {
        log "WiFi configuration skipped by user."
        return 0
      }
      # Scan and prompt for network
      ssid="$(nw_prompt_wifi_network "$wifi_iface" 5 || true)"
      if [[ -z "$ssid" ]]; then
        log "WiFi configuration skipped."
        return 0
      fi
      if [[ -t 0 ]]; then
        read -r -s -p "Enter Wi-Fi password for \"$ssid\" (blank for open): " pass; echo
      fi
      ;;
  esac

  [[ -n "$ssid" ]] || { err "SSID is empty."; return 1; }

  # Generate wpa_supplicant config
  nw_configure_wpa_supplicant "$wifi_iface" "$ssid" "$pass" >/dev/null || return 1

  # Enable wpa_supplicant service for this interface
  nw_enable_wpa_service "$wifi_iface"

  # Write /etc/network/interfaces.d/wifi-failover (idempotent)
  nw_write_wifi_failover_iface "$wifi_iface"

  # Ensure source line in /etc/network/interfaces
  nw_ensure_source_line

  # Set Ethernet metric if not bridged
  if [[ -n "$eth_iface" ]]; then
    nw_ensure_eth_metric "$eth_iface"
  fi

  # Bring up WiFi now
  ip link set "$wifi_iface" up >/dev/null 2>&1 || true
  ifup "$wifi_iface" >/dev/null 2>&1 || true

  log "WiFi failover configured: $wifi_iface (metric 200) with SSID $ssid"
  if [[ -n "$eth_iface" ]]; then
    log "Ethernet $eth_iface remains primary (lower metric)."
  fi
  warn "WiFi cannot be bridged into a Proxmox bridge without a VPN or routed setup."
}

# ---------------------------------------------------------------------------
# CPU and GPU governor configuration
# ---------------------------------------------------------------------------

configure_governors() {
  # Set CPU governor to powersave (saves power, doesn't affect server performance much)
  local governor="powersave"
  local gov_file changed=0

  if [[ "$CPU_POWERSAVE" == "yes" ]]; then
    for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      [[ -w "$gov_file" ]] || continue
      echo "$governor" > "$gov_file" 2>/dev/null && changed=1
    done
    (( changed )) && log "Set CPU governor to $governor."
  elif [[ "$CPU_PERFORMANCE" == "yes" ]]; then
    governor="performance"
    for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      [[ -w "$gov_file" ]] || continue
      echo "$governor" > "$gov_file" 2>/dev/null && changed=1
    done
    (( changed )) && log "Set CPU governor to $governor (powersave unavailable)."
  fi

  # Set GPU power mode to auto (let driver manage, no driver installs)
  for gov_file in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
    [[ -w "$gov_file" ]] || continue
    echo "auto" > "$gov_file" 2>/dev/null && log "Set GPU DPM to auto."
  done

  # Write boot config for persistence
  mkdir -p /etc/pve-sleep
  cat > /etc/pve-sleep/boot.conf <<EOF
# pve-sleep boot configuration — generated by pve-sleep-detect.sh
# Rerun the configurator to regenerate.
CPU_GOVERNOR=$governor
GPU_DPM=auto
USB_WAKE_MODE=all
EOF
  log "Wrote /etc/pve-sleep/boot.conf for boot-time persistence."
}

# ---------------------------------------------------------------------------
# Console blank configuration
# ---------------------------------------------------------------------------

configure_console_blank() {
  # Apply console blanking via setterm (default behavior, no prompt)
  local blank_min="${PVE_SLEEP_CONSOLE_BLANK_MINUTES:-5}"
  local powerdown_min="${PVE_SLEEP_CONSOLE_POWERDOWN_MINUTES:-10}"

  if have_cmd setterm; then
    local tty
    for tty in /dev/tty0 /dev/tty1 /dev/tty2 /dev/tty3 /dev/tty4 /dev/tty5 /dev/tty6; do
      [[ -w "$tty" ]] || continue
      setterm --blank "$blank_min" --powerdown "$powerdown_min" --powersave on > "$tty" 2>/dev/null || true
    done
    log "Console blank: ${blank_min}min blank, ${powerdown_min}min powerdown."
  fi

  # Check GRUB consoleblank setting and recommend if not configured
  if [[ "$GRUB_CONSOLEBLANK" == "not set" ]] && [[ -f /etc/default/grub ]]; then
    local cmdline
    cmdline="$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub 2>/dev/null || true)"
    if [[ -n "$cmdline" ]] && ! echo "$cmdline" | grep -q 'consoleblank='; then
      log "Tip: Add consoleblank=300 to GRUB_CMDLINE_LINUX_DEFAULT for persistent blank."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Sleep mode configuration
# ---------------------------------------------------------------------------

configure_sleep_modes() {
  # Only enable sleep on low battery — do NOT configure automatic suspend
  # Verify that suspend-to-RAM is available and WoL-compatible

  if [[ "$SUPPORTED_SLEEP_STATES" == *mem* ]]; then
    # Prefer deep (S3) for WoL compatibility; fall back to s2idle
    if [[ "$SUPPORTED_MEM_SLEEP" == *deep* ]]; then
      log "Sleep mode: suspend-to-RAM (deep/S3) available — compatible with WoL."
    elif [[ "$SUPPORTED_MEM_SLEEP" == *s2idle* ]]; then
      log "Sleep mode: s2idle available — compatible with WoL."
    fi
  else
    warn "No suspend-to-RAM support detected. Sleep functionality may be limited."
  fi

  # Ensure hibernate is NOT the default sleep action (it may not support WoL wake)
  if have_cmd systemctl; then
    local default_sleep
    default_sleep="$(systemctl get-default 2>/dev/null || true)"
    if [[ "$default_sleep" == "hibernate.target" ]]; then
      warn "Default target is hibernate — WoL may not wake from hibernate."
    fi
  fi

  log "Sleep is available but NOT auto-triggered. Battery monitor handles low-battery sleep."
}

# ---------------------------------------------------------------------------
# Boot service configuration (persistence across reboots)
# ---------------------------------------------------------------------------

configure_boot_service() {
  local prefix="${1:-/opt/pve-sleep}"

  # Enable the boot service if the service file exists
  if [[ -f "$prefix/bin/pve-sleep-boot.service" ]]; then
    if have_cmd systemctl; then
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl enable pve-sleep-boot.service >/dev/null 2>&1 || true
      systemctl start pve-sleep-boot.service >/dev/null 2>&1 || true
      log "Enabled pve-sleep-boot.service for persistent settings."
    fi
  fi
}
