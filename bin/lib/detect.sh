#!/usr/bin/env bash
# =============================================================================
# pve-sleep: detect.sh — hardware and system configuration detection
# =============================================================================
set -u

# ---------------------------------------------------------------------------
# Global detection variables (populated by detect functions)
# ---------------------------------------------------------------------------

HOSTNAME_VAL="unknown"; KERNEL_VAL="unknown"; ARCH_VAL="unknown"; DISTRO_VAL="unknown"
DEBIAN_VER="unknown"; DEBIAN_CODENAME="unknown"
PVE_VERSION_RAW="not detected"; PVE_MAJOR="unknown"

CPU_VENDOR="unknown"; CPU_GOVERNORS=""; CPU_GOVERNOR_PRESENT="no"
CPU_POWERSAVE="no"; CPU_PERFORMANCE="no"; CPU_CURRENT_GOVERNOR="unknown"
GPU_CONTROL_PRESENT="no"; GPU_CONTROL_SUMMARY="none detected"

HAS_LID="no"; HAS_DISPLAY="no"; HAS_BUILTIN_DISPLAY="no"
DISPLAY_SUMMARY="none detected"
HAS_BATTERY="no"; BATTERY_SUMMARY="none detected"

SUPPORTED_SLEEP_STATES="unknown"; SUPPORTED_MEM_SLEEP="unknown"
RTC_WAKE_SUPPORTED="no"
WOL_SUPPORTED_TOTAL=0; WOWLAN_SUPPORTED_TOTAL=0
USB_WAKE_CAPABLE_TOTAL=0; USB_WAKE_ENABLED_TOTAL=0
SUPPORTED_WAKE_SUMMARY="none detected"

LOGIND_LID="default"; LOGIND_IDLE_ACTION="ignore"; LOGIND_IDLE_SECS="none"
SLEEP_CONF_LIMITS="none"; GRUB_CONSOLEBLANK="not set"
CONSOLE_BLANK_CURRENT="unknown"
RELEVANT_TIMER_SUMMARY="none"; INHIBITOR_SUMMARY="none"

declare -a NETWORK_LINES=() NETWORK_JSON=()
declare -a USB_LINES=() USB_JSON=()
declare -a SERVICE_LINES=() TIMER_LINES=() LIMITATIONS=()

# ---------------------------------------------------------------------------
# System information
# ---------------------------------------------------------------------------

detect_system_info() {
  HOSTNAME_VAL="$(hostname 2>/dev/null || echo unknown)"
  KERNEL_VAL="$(uname -r 2>/dev/null || echo unknown)"
  ARCH_VAL="$(uname -m 2>/dev/null || echo unknown)"

  if [[ -r /etc/os-release ]]; then
    DISTRO_VAL="$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-${NAME:-unknown}}")"
    DEBIAN_VER="$(. /etc/os-release; printf '%s' "${VERSION_ID:-unknown}")"
    DEBIAN_CODENAME="$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-unknown}")"
  fi

  if have_cmd pveversion; then
    PVE_VERSION_RAW="$(pveversion 2>/dev/null | head -n1)"
    PVE_MAJOR="$(printf '%s\n' "$PVE_VERSION_RAW" | sed -nE 's|.*pve-manager/([0-9]+).*|\1|p')"
    [[ -n "$PVE_MAJOR" ]] || PVE_MAJOR="unknown"
  fi
}

# ---------------------------------------------------------------------------
# CPU and GPU
# ---------------------------------------------------------------------------

detect_cpu_gpu() {
  CPU_VENDOR="$(awk -F: '/^vendor_id/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
  [[ -n "$CPU_VENDOR" ]] || CPU_VENDOR="unknown"

  CPU_GOVERNORS="$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_available_governors 2>/dev/null \
    | tr ' ' '\n' | awk 'NF' | sort -u | xargs)"
  if [[ -n "$CPU_GOVERNORS" ]]; then
    CPU_GOVERNOR_PRESENT="yes"
    [[ " $CPU_GOVERNORS " == *" powersave "* ]] && CPU_POWERSAVE="yes"
    [[ " $CPU_GOVERNORS " == *" performance "* ]] && CPU_PERFORMANCE="yes"
  fi

  CPU_CURRENT_GOVERNOR="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"

  # GPU power controls (read-only detection — no driver installs)
  local gpu_lines=() file value card
  for file in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
    [[ -r "$file" ]] || continue
    value="$(tr '\n' ' ' < "$file" | xargs)"
    card="$(basename "$(dirname "$(dirname "$file")")")"
    gpu_lines+=("$card/dpm=$value")
  done
  for file in /sys/class/drm/card*/device/power/control; do
    [[ -r "$file" ]] || continue
    value="$(tr '\n' ' ' < "$file" | xargs)"
    card="$(basename "$(dirname "$(dirname "$(dirname "$file")")")")"
    gpu_lines+=("$card/power=$value")
  done

  if (( ${#gpu_lines[@]} > 0 )); then
    GPU_CONTROL_PRESENT="yes"
    GPU_CONTROL_SUMMARY="$(printf '%s; ' "${gpu_lines[@]}")"
    GPU_CONTROL_SUMMARY="${GPU_CONTROL_SUMMARY%; }"
  fi
}

# ---------------------------------------------------------------------------
# Lid, display, battery
# ---------------------------------------------------------------------------

detect_lid_display_battery() {
  # Lid switch
  local lid_hit
  lid_hit="$(find /proc/acpi/button/lid -mindepth 1 -maxdepth 2 2>/dev/null | head -n1 || true)"
  if [[ -n "$lid_hit" ]] || grep -qi 'lid switch' /proc/bus/input/devices 2>/dev/null; then
    HAS_LID="yes"
  fi

  # Displays
  local display_lines=() connector status enabled_file
  for enabled_file in /sys/class/drm/*/status; do
    [[ -r "$enabled_file" ]] || continue
    connector="$(basename "$(dirname "$enabled_file")")"
    status="$(tr -d '\n' < "$enabled_file")"
    display_lines+=("$connector=$status")
    [[ "$status" != "disconnected" ]] && HAS_DISPLAY="yes"
    case "$connector" in
      eDP-*|LVDS-*|DSI-*) HAS_BUILTIN_DISPLAY="yes"; HAS_DISPLAY="yes" ;;
    esac
  done

  local backlight_count
  backlight_count="$(find /sys/class/backlight -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
  (( backlight_count > 0 )) && { HAS_BUILTIN_DISPLAY="yes"; HAS_DISPLAY="yes"; }

  if (( ${#display_lines[@]} > 0 )); then
    DISPLAY_SUMMARY="$(printf '%s; ' "${display_lines[@]}")"
    DISPLAY_SUMMARY="${DISPLAY_SUMMARY%; }"
  fi

  # Battery
  local bat_count=0 bat name bstatus
  for bat in /sys/class/power_supply/BAT*; do
    [[ -e "$bat" ]] || continue
    bat_count=$((bat_count + 1))
    name="$(basename "$bat")"
    bstatus="$(cat "$bat/status" 2>/dev/null || echo unknown)"
    SERVICE_LINES+=("- battery: $name=$bstatus")
  done
  if (( bat_count > 0 )); then
    HAS_BATTERY="yes"
    BATTERY_SUMMARY="${bat_count} battery device(s)"
  fi
}

# ---------------------------------------------------------------------------
# Network adapters
# ---------------------------------------------------------------------------

detect_network_adapters() {
  NETWORK_LINES=(); NETWORK_JSON=()
  WOL_SUPPORTED_TOTAL=0; WOWLAN_SUPPORTED_TOTAL=0

  local path iface type driver state mac wol_support wol_current wowlan power_ctrl
  for path in /sys/class/net/*; do
    iface="$(basename "$path")"
    nw_is_physical_iface "$iface" || continue

    type="$(nw_iface_type "$iface")"
    driver="$(basename "$(readlink -f "$path/device/driver" 2>/dev/null)" 2>/dev/null || true)"
    [[ -n "$driver" ]] || driver="unknown"
    state="$(cat "$path/operstate" 2>/dev/null || echo unknown)"
    mac="$(cat "$path/address" 2>/dev/null || echo unknown)"
    wol_support="unknown"; wol_current="unknown"; wowlan="no"
    power_ctrl="$(cat "$path/device/power/control" 2>/dev/null || echo unknown)"

    if [[ "$type" == "ethernet" ]] && have_cmd ethtool; then
      local etool
      etool="$(ethtool "$iface" 2>/dev/null || true)"
      wol_support="$(awk -F': ' '/Supports Wake-on:/ {print $2; exit}' <<< "$etool")"
      wol_current="$(awk -F': ' '/^[[:space:]]*Wake-on:/ {print $2; exit}' <<< "$etool")"
      [[ -n "$wol_support" ]] || wol_support="unknown"
      [[ -n "$wol_current" ]] || wol_current="unknown"
      if [[ -n "$wol_support" && "$wol_support" != "d" && "$wol_support" != "unknown" ]]; then
        WOL_SUPPORTED_TOTAL=$((WOL_SUPPORTED_TOTAL + 1))
      fi
    fi

    if [[ "$type" == "wifi" ]] && have_cmd iw; then
      local phy
      phy="$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/ {print "phy"$2; exit}')"
      if [[ -n "$phy" ]] && iw phy "$phy" info 2>/dev/null | grep -q 'WoWLAN support'; then
        wowlan="yes"
        WOWLAN_SUPPORTED_TOTAL=$((WOWLAN_SUPPORTED_TOTAL + 1))
      fi
    fi

    NETWORK_LINES+=("- $iface ($type, driver=$driver, state=$state, mac=$mac, wol_support=$wol_support, wol_current=$wol_current, wowlan=$wowlan, power=$power_ctrl)")
    NETWORK_JSON+=("{\"name\":\"$(json_escape "$iface")\",\"type\":\"$(json_escape "$type")\",\"driver\":\"$(json_escape "$driver")\",\"state\":\"$(json_escape "$state")\",\"mac\":\"$(json_escape "$mac")\",\"wol_support\":\"$(json_escape "$wol_support")\",\"wol_current\":\"$(json_escape "$wol_current")\",\"wowlan\":\"$(json_escape "$wowlan")\",\"power_control\":\"$(json_escape "$power_ctrl")\"}")
  done
}

# ---------------------------------------------------------------------------
# USB devices
# ---------------------------------------------------------------------------

detect_usb_devices() {
  USB_LINES=(); USB_JSON=()
  USB_WAKE_CAPABLE_TOTAL=0; USB_WAKE_ENABLED_TOTAL=0

  local dev manufacturer product vendor_id product_id wake power_ctrl
  for dev in /sys/bus/usb/devices/*; do
    [[ -r "$dev/idVendor" ]] || continue
    manufacturer="$(cat "$dev/manufacturer" 2>/dev/null || echo unknown)"
    product="$(cat "$dev/product" 2>/dev/null || echo unknown)"
    vendor_id="$(cat "$dev/idVendor" 2>/dev/null || echo unknown)"
    product_id="$(cat "$dev/idProduct" 2>/dev/null || echo unknown)"
    wake="n/a"; power_ctrl="n/a"

    if [[ -r "$dev/power/wakeup" ]]; then
      wake="$(cat "$dev/power/wakeup" 2>/dev/null || echo unknown)"
      USB_WAKE_CAPABLE_TOTAL=$((USB_WAKE_CAPABLE_TOTAL + 1))
      [[ "$wake" == "enabled" ]] && USB_WAKE_ENABLED_TOTAL=$((USB_WAKE_ENABLED_TOTAL + 1))
    fi
    if [[ -r "$dev/power/control" ]]; then
      power_ctrl="$(cat "$dev/power/control" 2>/dev/null || echo unknown)"
    fi

    USB_LINES+=("- $(basename "$dev") ($manufacturer $product, ${vendor_id}:${product_id}, wake=$wake, power=$power_ctrl)")
    USB_JSON+=("{\"device\":\"$(json_escape "$(basename "$dev")")\",\"manufacturer\":\"$(json_escape "$manufacturer")\",\"product\":\"$(json_escape "$product")\",\"vendor_id\":\"$(json_escape "$vendor_id")\",\"product_id\":\"$(json_escape "$product_id")\",\"wake\":\"$(json_escape "$wake")\",\"power_control\":\"$(json_escape "$power_ctrl")\"}")
  done
}

# ---------------------------------------------------------------------------
# Sleep and wake modes
# ---------------------------------------------------------------------------

detect_sleep_wake() {
  SUPPORTED_SLEEP_STATES="$(tr '\n' ' ' < /sys/power/state 2>/dev/null | xargs || true)"
  [[ -n "$SUPPORTED_SLEEP_STATES" ]] || SUPPORTED_SLEEP_STATES="unknown"

  SUPPORTED_MEM_SLEEP="$(tr '\n' ' ' < /sys/power/mem_sleep 2>/dev/null | xargs || true)"
  [[ -n "$SUPPORTED_MEM_SLEEP" ]] || SUPPORTED_MEM_SLEEP="unknown"

  [[ -e /sys/class/rtc/rtc0/wakealarm ]] && RTC_WAKE_SUPPORTED="yes"

  local wake_modes=()
  [[ "$HAS_LID" == "yes" ]] && wake_modes+=("lid")
  [[ "$RTC_WAKE_SUPPORTED" == "yes" ]] && wake_modes+=("rtc")
  (( USB_WAKE_CAPABLE_TOTAL > 0 )) && wake_modes+=("usb")
  (( WOL_SUPPORTED_TOTAL > 0 )) && wake_modes+=("wake-on-lan")
  (( WOWLAN_SUPPORTED_TOTAL > 0 )) && wake_modes+=("wake-on-wireless-lan")

  if (( ${#wake_modes[@]} > 0 )); then
    SUPPORTED_WAKE_SUMMARY="$(printf '%s, ' "${wake_modes[@]}")"
    SUPPORTED_WAKE_SUMMARY="${SUPPORTED_WAKE_SUMMARY%, }"
  fi

  # Sleep mode limitations
  [[ "$SUPPORTED_SLEEP_STATES" == *mem* ]] || LIMITATIONS+=("Suspend-to-RAM (mem) not available.")
  [[ "$SUPPORTED_SLEEP_STATES" == *disk* ]] || LIMITATIONS+=("Hibernate (disk) not available.")

  # WoL compatibility check
  if [[ "$SUPPORTED_MEM_SLEEP" != *deep* && "$SUPPORTED_MEM_SLEEP" != *s2idle* ]]; then
    [[ "$SUPPORTED_SLEEP_STATES" == *mem* ]] && \
      LIMITATIONS+=("mem_sleep modes are limited — WoL wake may not be reliable.")
  fi
}

# ---------------------------------------------------------------------------
# Power configuration (services, logind, timers, inhibitors)
# ---------------------------------------------------------------------------

detect_power_config() {
  local unit state enabled

  for unit in sleep.target suspend.target hibernate.target \
              hybrid-sleep.target suspend-then-hibernate.target \
              console-blank.service pve-battery-monitor.service \
              pve-network-failover.service pve-sleep-boot.service; do
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || echo unknown)"
    state="$(systemctl is-active "$unit" 2>/dev/null || echo unknown)"
    SERVICE_LINES+=("- $unit: enabled=$enabled active=$state")
    [[ "$enabled" == "masked" ]] && LIMITATIONS+=("$unit is masked — blocks this sleep mode.")
  done

  # logind
  LOGIND_LID="$(grep -Rhs '^[[:space:]]*HandleLidSwitch=' \
    /etc/systemd/logind.conf /etc/systemd/logind.conf.d/*.conf 2>/dev/null \
    | tail -n1 | cut -d= -f2- | xargs || true)"
  [[ -n "$LOGIND_LID" ]] || LOGIND_LID="default"

  LOGIND_IDLE_ACTION="$(grep -Rhs '^[[:space:]]*IdleAction=' \
    /etc/systemd/logind.conf /etc/systemd/logind.conf.d/*.conf 2>/dev/null \
    | tail -n1 | cut -d= -f2- | xargs || true)"
  [[ -n "$LOGIND_IDLE_ACTION" ]] || LOGIND_IDLE_ACTION="ignore"

  LOGIND_IDLE_SECS="$(grep -Rhs '^[[:space:]]*IdleActionSec=' \
    /etc/systemd/logind.conf /etc/systemd/logind.conf.d/*.conf 2>/dev/null \
    | tail -n1 | cut -d= -f2- | xargs || true)"
  [[ -n "$LOGIND_IDLE_SECS" ]] || LOGIND_IDLE_SECS="none"

  [[ "$LOGIND_LID" == "ignore" && "$HAS_LID" == "yes" ]] && \
    LIMITATIONS+=("logind HandleLidSwitch=ignore — lid switch takes no action.")
  [[ "$LOGIND_IDLE_ACTION" != "ignore" ]] && \
    LIMITATIONS+=("logind IdleAction=$LOGIND_IDLE_ACTION — may trigger power changes after $LOGIND_IDLE_SECS.")

  # sleep.conf overrides
  local tmp
  tmp="$(grep -RhsE '^[[:space:]]*(AllowSuspend|AllowHibernation|AllowHybridSleep|AllowSuspendThenHibernate)=' \
    /etc/systemd/sleep.conf /etc/systemd/sleep.conf.d/*.conf 2>/dev/null || true)"
  if [[ -n "$tmp" ]]; then
    SLEEP_CONF_LIMITS="$(printf '%s' "$tmp" | tr '\n' '; ' | sed 's/; $//')"
    while IFS= read -r line; do
      [[ -n "$line" ]] && LIMITATIONS+=("sleep.conf: $line")
    done <<< "$tmp"
  fi

  # GRUB consoleblank
  GRUB_CONSOLEBLANK="$(grep -Eo 'consoleblank=[^" ]+' /etc/default/grub 2>/dev/null | head -n1 || true)"
  [[ -n "$GRUB_CONSOLEBLANK" ]] || GRUB_CONSOLEBLANK="not set"

  CONSOLE_BLANK_CURRENT="$(awk -v RS=' ' '/^consoleblank=/{sub(/.*=/,""); print}' /proc/cmdline 2>/dev/null || true)"
  [[ -n "$CONSOLE_BLANK_CURRENT" ]] || CONSOLE_BLANK_CURRENT="kernel default (600s)"

  # RTC alarm
  local rtc_alarm
  rtc_alarm="$(cat /sys/class/rtc/rtc0/wakealarm 2>/dev/null || true)"
  if [[ -n "$rtc_alarm" && "$rtc_alarm" != "0" ]]; then
    TIMER_LINES+=("- rtc0 wakealarm: $rtc_alarm")
    LIMITATIONS+=("RTC wake alarm is active — may cause unexpected wake.")
  fi

  # Sleep/wake related timers only (not all system timers)
  tmp="$(systemctl list-timers --all --no-pager 2>/dev/null \
    | grep -Ei 'sleep|suspend|hibernate|wake' | head -n 5 || true)"
  if [[ -n "$tmp" ]]; then
    RELEVANT_TIMER_SUMMARY="present"
    while IFS= read -r line; do
      [[ -n "$line" ]] && TIMER_LINES+=("- $line")
    done <<< "$tmp"
  fi

  # Inhibitors (summary only)
  if have_cmd systemd-inhibit; then
    tmp="$(systemd-inhibit --list 2>/dev/null | awk 'NR>1 && NF' | head -n 5 || true)"
    if [[ -n "$tmp" ]]; then
      local count
      count="$(printf '%s\n' "$tmp" | wc -l | tr -d ' ')"
      INHIBITOR_SUMMARY="$count inhibitor(s) active"
      LIMITATIONS+=("Active systemd inhibitors may block or delay sleep.")
    fi
  fi

  # Proxmox guest risk
  have_cmd pveversion && \
    LIMITATIONS+=("Running Proxmox guests will be disrupted by host suspend. Use safe-sleep first.")
}

# ---------------------------------------------------------------------------
# Run all detection
# ---------------------------------------------------------------------------

run_all_detection() {
  detect_system_info
  detect_cpu_gpu
  detect_lid_display_battery
  detect_network_adapters
  detect_usb_devices
  detect_sleep_wake
  detect_power_config
}
