#!/usr/bin/env bash
set -u

VERSION="0.1.0"
SCRIPT_SOURCE="${BASH_SOURCE[0]:-${0:-}}"
if [[ -n "$SCRIPT_SOURCE" && "$SCRIPT_SOURCE" != "bash" && "$SCRIPT_SOURCE" != "-bash" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
else
  SCRIPT_DIR="$PWD"
fi
OUTPUT_DIR="$SCRIPT_DIR"
PROBE_WRITE=0
INSTALL_MISSING=0
ENABLE_WAKE=0
CONFIGURE_WIFI=0
POST_INSTALL=0

while (($#)); do
  case "$1" in
    --probe-write)
      PROBE_WRITE=1
      shift
      ;;
    --install-missing)
      INSTALL_MISSING=1
      shift
      ;;
    --enable-wake)
      ENABLE_WAKE=1
      shift
      ;;
    --configure-wifi)
      CONFIGURE_WIFI=1
      shift
      ;;
    --post-install)
      POST_INSTALL=1
      shift
      ;;
    --output-dir)
      if [[ -z "${2:-}" ]]; then
        echo "Missing value for --output-dir" >&2
        exit 1
      fi
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
pve-sleep-detect.sh [--probe-write] [--install-missing] [--enable-wake] [--configure-wifi] [--output-dir DIR]

Detects sleep and wake capabilities on Proxmox/Debian systems.
It does not make permanent changes by default. When --probe-write is used, it only
attempts no-op writes by writing the current value back to supported sysfs files.
Use --install-missing to prompt once for all safe package installs.
Use --enable-wake to enable Wake-on-LAN and Wake-on-Wireless-LAN where supported.
Use --configure-wifi to scan the top 5 Wi-Fi networks and configure failover.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$OUTPUT_DIR"
TXT_OUT="$OUTPUT_DIR/sleep-system.txt"
JSON_OUT="$OUTPUT_DIR/sleep-system.json"

CHECK="✅"
CROSS="❌"
WARN="⚠️"

HOSTNAME_VAL="$(hostname 2>/dev/null || echo unknown)"
KERNEL_VAL="$(uname -r 2>/dev/null || echo unknown)"
ARCH_VAL="$(uname -m 2>/dev/null || echo unknown)"
DISTRO_VAL="unknown"
DEBIAN_VER="unknown"
DEBIAN_CODENAME="unknown"
PVE_VERSION_RAW="not detected"
PVE_MAJOR="unknown"

CPU_VENDOR="unknown"
CPU_GOVERNORS=""
CPU_GOVERNOR_PRESENT="no"
CPU_POWERSAVE="no"
CPU_PERFORMANCE="no"
GPU_CONTROL_PRESENT="no"
GPU_CONTROL_SUMMARY="none detected"

HAS_LID="no"
HAS_DISPLAY="no"
HAS_BUILTIN_DISPLAY="no"
DISPLAY_SUMMARY="none detected"
HAS_BATTERY="no"
BATTERY_SUMMARY="none detected"

WOL_SUPPORTED_TOTAL=0
WOWLAN_SUPPORTED_TOTAL=0
USB_WAKE_CAPABLE_TOTAL=0
USB_WAKE_ENABLED_TOTAL=0
RTC_WAKE_SUPPORTED="no"
SUPPORTED_SLEEP_STATES="unknown"
SUPPORTED_MEM_SLEEP="unknown"
SUPPORTED_WAKE_SUMMARY=""

LOGIND_LID="default"
LOGIND_IDLE_ACTION="ignore"
LOGIND_IDLE_SECS="none"
SLEEP_CONF_LIMITS="none found"
GRUB_CONSOLEBLANK="not explicitly set"
RELEVANT_TIMER_SUMMARY="none found"
INHIBITOR_SUMMARY="none found"

declare -a REPORT_LINES=() LIMITATIONS=() NEEDED_PACKAGES=() MISSING_PACKAGES=() NEEDED_PACKAGE_NAMES=()
declare -a NETWORK_LINES=() NETWORK_JSON=() USB_LINES=() USB_JSON=()
declare -a SERVICE_LINES=() TIMER_LINES=()

HELPER_DIR="$SCRIPT_DIR"
[[ -r "$HELPER_DIR/aptfunctions.sh" ]] || HELPER_DIR="$SCRIPT_DIR/bin"
[[ -r "$HELPER_DIR/aptfunctions.sh" ]] && . "$HELPER_DIR/aptfunctions.sh"
[[ -r "$HELPER_DIR/networkwake.sh" ]] && . "$HELPER_DIR/networkwake.sh"

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

mark() {
  if [[ "$1" == "yes" ]]; then
    printf '%s' "$CHECK"
  else
    printf '%s' "$CROSS"
  fi
}

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

array_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

append_unique_line() {
  local line="$1"
  local array_name="$2"
  local existing=()
  eval "existing=(\"\${${array_name}[@]}\")"
  if ! array_contains "$line" "${existing[@]}"; then
    eval "${array_name}+=(\"\$line\")"
  fi
}

json_string_array() {
  local array_name="$1"
  local first=1
  local item
  local values=()
  eval "values=(\"\${${array_name}[@]}\")"
  printf '['
  for item in "${values[@]}"; do
    [[ $first -eq 1 ]] || printf ','
    printf '"%s"' "$(json_escape "$item")"
    first=0
  done
  printf ']'
}

json_raw_array() {
  local array_name="$1"
  local first=1
  local item
  local values=()
  eval "values=(\"\${${array_name}[@]}\")"
  printf '['
  for item in "${values[@]}"; do
    [[ $first -eq 1 ]] || printf ','
    printf '%s' "$item"
    first=0
  done
  printf ']'
}


parse_proxmox() {
  if have_cmd pveversion; then
    PVE_VERSION_RAW="$(pveversion 2>/dev/null | head -n1)"
    PVE_MAJOR="$(printf '%s\n' "$PVE_VERSION_RAW" | sed -nE 's|.*pve-manager/([0-9]+).*|\1|p')"
    [[ -n "$PVE_MAJOR" ]] || PVE_MAJOR="unknown"
  fi

  if [[ -r /etc/os-release ]]; then
    DISTRO_VAL="$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-${NAME:-unknown}}")"
    DEBIAN_VER="$(. /etc/os-release; printf '%s' "${VERSION_ID:-unknown}")"
    DEBIAN_CODENAME="$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-unknown}")"
  fi
}

parse_cpu_and_gpu() {
  CPU_VENDOR="$(awk -F: '/^vendor_id/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  [[ -n "$CPU_VENDOR" ]] || CPU_VENDOR="unknown"

  CPU_GOVERNORS="$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_available_governors 2>/dev/null | tr ' ' '\n' | awk 'NF' | sort -u | xargs)"
  if [[ -n "$CPU_GOVERNORS" ]]; then
    CPU_GOVERNOR_PRESENT="yes"
    [[ " $CPU_GOVERNORS " == *" powersave "* ]] && CPU_POWERSAVE="yes"
    [[ " $CPU_GOVERNORS " == *" performance "* ]] && CPU_PERFORMANCE="yes"
  fi

  local gpu_lines=()
  local file value
  for file in /sys/class/drm/card*/device/power_dpm_force_performance_level /sys/class/drm/card*/device/power_dpm_state /sys/class/drm/card*/device/power/control; do
    [[ -r "$file" ]] || continue
    value="$(tr '\n' ' ' < "$file" | xargs)"
    gpu_lines+=("$(printf '%s=%s' "${file#/sys/class/drm/}" "$value")")
  done

  if ((${#gpu_lines[@]} > 0)); then
    GPU_CONTROL_PRESENT="yes"
    GPU_CONTROL_SUMMARY="$(printf '%s; ' "${gpu_lines[@]}")"
    GPU_CONTROL_SUMMARY="${GPU_CONTROL_SUMMARY%; }"
  fi
}

parse_lid_display_battery() {
  local lid_hits display_lines=() connector status enabled_file enabled backlight_count

  lid_hits="$(find /proc/acpi/button/lid -mindepth 1 -maxdepth 2 2>/dev/null | head -n1 || true)"
  if [[ -n "$lid_hits" ]] || grep -qi 'lid switch' /proc/bus/input/devices 2>/dev/null; then
    HAS_LID="yes"
  fi

  for enabled_file in /sys/class/drm/*/status; do
    [[ -r "$enabled_file" ]] || continue
    connector="$(basename "$(dirname "$enabled_file")")"
    status="$(tr -d '\n' < "$enabled_file")"
    display_lines+=("$connector=$status")
    if [[ "$status" != "disconnected" ]]; then
      HAS_DISPLAY="yes"
    fi
    if [[ "$connector" == eDP-* || "$connector" == LVDS-* || "$connector" == DSI-* ]]; then
      HAS_BUILTIN_DISPLAY="yes"
      HAS_DISPLAY="yes"
    fi
  done

  backlight_count="$(find /sys/class/backlight -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$backlight_count" != "0" ]]; then
    HAS_BUILTIN_DISPLAY="yes"
    HAS_DISPLAY="yes"
  fi

  if ((${#display_lines[@]} > 0)); then
    DISPLAY_SUMMARY="$(printf '%s; ' "${display_lines[@]}")"
    DISPLAY_SUMMARY="${DISPLAY_SUMMARY%; }"
  fi

  local bat_count=0 bat name status
  for bat in /sys/class/power_supply/BAT*; do
    [[ -e "$bat" ]] || continue
    bat_count=$((bat_count + 1))
    name="$(basename "$bat")"
    status="$(cat "$bat/status" 2>/dev/null || echo unknown)"
    append_unique_line "$name=$status" SERVICE_LINES
  done
  if ((bat_count > 0)); then
    HAS_BATTERY="yes"
    BATTERY_SUMMARY="${bat_count} battery device(s) present"
  fi
}

classify_iface() {
  local iface="$1"
  if [[ -d "/sys/class/net/$iface/wireless" ]]; then
    printf '%s' "wifi"
  else
    printf '%s' "ethernet"
  fi
}

parse_network() {
  local path iface type driver state mac supports wake wowlan
  for path in /sys/class/net/*; do
    iface="$(basename "$path")"
    [[ "$iface" == "lo" ]] && continue
    [[ -e "$path/device" ]] || continue
    case "$iface" in
      vmbr*|veth*|tap*|fwln*|fwbr*|fwpr*|docker*|virbr*|br-*|vnet*)
        continue
        ;;
    esac

    if have_cmd nw_iface_type; then
      type="$(nw_iface_type "$iface")"
    else
      type="$(classify_iface "$iface")"
    fi

    driver="$(basename "$(readlink -f "$path/device/driver" 2>/dev/null)")"
    [[ -n "$driver" ]] || driver="unknown"
    state="$(cat "$path/operstate" 2>/dev/null || echo unknown)"
    mac="$(cat "$path/address" 2>/dev/null || echo unknown)"
    supports="unknown"
    wake="unknown"
    wowlan="no"

    if have_cmd nw_get_wol_support; then
      supports="$(nw_get_wol_support "$iface" 2>/dev/null || echo unknown)"
      wake="$(nw_get_wol_current "$iface" 2>/dev/null || echo unknown)"
    fi

    if [[ -n "$supports" && "$supports" != "d" && "$supports" != "unknown" ]]; then
      WOL_SUPPORTED_TOTAL=$((WOL_SUPPORTED_TOTAL + 1))
    fi

    if [[ "$type" == "wifi" ]] && have_cmd nw_get_wowlan_support; then
      if [[ "$(nw_get_wowlan_support "$iface" 2>/dev/null || echo no)" == "yes" ]]; then
        wowlan="yes"
        WOWLAN_SUPPORTED_TOTAL=$((WOWLAN_SUPPORTED_TOTAL + 1))
      fi
    fi

    NETWORK_LINES+=("- $iface ($type, driver=$driver, state=$state, mac=$mac, wol_support=${supports:-unknown}, wol_current=${wake:-unknown}, wowlan=$wowlan)")
    NETWORK_JSON+=("{\"name\":\"$(json_escape "$iface")\",\"type\":\"$(json_escape "$type")\",\"driver\":\"$(json_escape "$driver")\",\"state\":\"$(json_escape "$state")\",\"mac\":\"$(json_escape "$mac")\",\"wol_support\":\"$(json_escape "${supports:-unknown}")\",\"wol_current\":\"$(json_escape "${wake:-unknown}")\",\"wowlan\":\"$(json_escape "$wowlan")\"}")
  done
}

parse_usb() {
  local dev manufacturer product vendor_id product_id wake probe_ok entry
  for dev in /sys/bus/usb/devices/*; do
    [[ -r "$dev/idVendor" ]] || continue
    manufacturer="$(cat "$dev/manufacturer" 2>/dev/null || echo unknown)"
    product="$(cat "$dev/product" 2>/dev/null || echo unknown)"
    vendor_id="$(cat "$dev/idVendor" 2>/dev/null || echo unknown)"
    product_id="$(cat "$dev/idProduct" 2>/dev/null || echo unknown)"
    wake="n/a"
    probe_ok="not attempted"
    if [[ -r "$dev/power/wakeup" ]]; then
      wake="$(cat "$dev/power/wakeup" 2>/dev/null || echo unknown)"
      USB_WAKE_CAPABLE_TOTAL=$((USB_WAKE_CAPABLE_TOTAL + 1))
      [[ "$wake" == "enabled" ]] && USB_WAKE_ENABLED_TOTAL=$((USB_WAKE_ENABLED_TOTAL + 1))
      if ((PROBE_WRITE == 1)) && [[ -w "$dev/power/wakeup" ]]; then
        if printf '%s' "$wake" > "$dev/power/wakeup" 2>/dev/null; then
          probe_ok="yes"
        else
          probe_ok="no"
        fi
      fi
    fi
    entry="- $(basename "$dev") (${manufacturer} ${product}, ${vendor_id}:${product_id}, wake=$wake, probe_write=$probe_ok)"
    USB_LINES+=("$entry")
    USB_JSON+=("{\"device\":\"$(json_escape "$(basename "$dev")")\",\"manufacturer\":\"$(json_escape "$manufacturer")\",\"product\":\"$(json_escape "$product")\",\"vendor_id\":\"$(json_escape "$vendor_id")\",\"product_id\":\"$(json_escape "$product_id")\",\"wake\":\"$(json_escape "$wake")\",\"probe_write\":\"$(json_escape "$probe_ok")\"}")
  done
}

parse_sleep_and_wake() {
  SUPPORTED_SLEEP_STATES="$(tr '\n' ' ' < /sys/power/state 2>/dev/null | xargs || true)"
  [[ -n "$SUPPORTED_SLEEP_STATES" ]] || SUPPORTED_SLEEP_STATES="unknown"
  SUPPORTED_MEM_SLEEP="$(tr '\n' ' ' < /sys/power/mem_sleep 2>/dev/null | xargs || true)"
  [[ -n "$SUPPORTED_MEM_SLEEP" ]] || SUPPORTED_MEM_SLEEP="unknown"

  if [[ -w /sys/class/rtc/rtc0/wakealarm || -r /sys/class/rtc/rtc0/wakealarm ]]; then
    RTC_WAKE_SUPPORTED="yes"
  fi

  local wake_modes=()
  [[ "$HAS_LID" == "yes" ]] && wake_modes+=("lid")
  [[ "$RTC_WAKE_SUPPORTED" == "yes" ]] && wake_modes+=("rtc")
  ((USB_WAKE_CAPABLE_TOTAL > 0)) && wake_modes+=("usb")
  ((WOL_SUPPORTED_TOTAL > 0)) && wake_modes+=("wake-on-lan")
  ((WOWLAN_SUPPORTED_TOTAL > 0)) && wake_modes+=("wake-on-wireless-lan")

  if ((${#wake_modes[@]} > 0)); then
    SUPPORTED_WAKE_SUMMARY="$(printf '%s, ' "${wake_modes[@]}")"
    SUPPORTED_WAKE_SUMMARY="${SUPPORTED_WAKE_SUMMARY%, }"
  else
    SUPPORTED_WAKE_SUMMARY="none detected"
  fi

  [[ "$SUPPORTED_SLEEP_STATES" == *mem* ]] || LIMITATIONS+=("Suspend-to-RAM (mem) is not exposed by /sys/power/state.")
  [[ "$SUPPORTED_SLEEP_STATES" == *disk* ]] || LIMITATIONS+=("Hibernate (disk) is not exposed by /sys/power/state.")
}

parse_power_configs() {
  local unit state enabled tmp line rtc_alarm inhibitors_count

  for unit in sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target console-blank.service pve-battery-monitor.service pve-network-failover.service; do
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    [[ -n "$enabled" ]] || enabled="unknown"
    [[ -n "$state" ]] || state="unknown"
    SERVICE_LINES+=("- $unit: enabled=$enabled active=$state")
    if [[ "$enabled" == "masked" ]]; then
      LIMITATIONS+=("$unit is masked, which blocks its sleep mode.")
    fi
  done

  LOGIND_LID="$(grep -Rhs '^[[:space:]]*HandleLidSwitch=' /etc/systemd/logind.conf /etc/systemd/logind.conf.d/*.conf 2>/dev/null | tail -n1 | cut -d= -f2- | xargs || true)"
  [[ -n "$LOGIND_LID" ]] || LOGIND_LID="default"
  LOGIND_IDLE_ACTION="$(grep -Rhs '^[[:space:]]*IdleAction=' /etc/systemd/logind.conf /etc/systemd/logind.conf.d/*.conf 2>/dev/null | tail -n1 | cut -d= -f2- | xargs || true)"
  [[ -n "$LOGIND_IDLE_ACTION" ]] || LOGIND_IDLE_ACTION="ignore"
  LOGIND_IDLE_SECS="$(grep -Rhs '^[[:space:]]*IdleActionSec=' /etc/systemd/logind.conf /etc/systemd/logind.conf.d/*.conf 2>/dev/null | tail -n1 | cut -d= -f2- | xargs || true)"
  [[ -n "$LOGIND_IDLE_SECS" ]] || LOGIND_IDLE_SECS="none"

  if [[ "$LOGIND_LID" == "ignore" ]]; then
    LIMITATIONS+=("systemd-logind is configured to ignore the lid switch.")
  fi
  if [[ "$LOGIND_IDLE_ACTION" != "ignore" ]]; then
    LIMITATIONS+=("IdleAction=$LOGIND_IDLE_ACTION may trigger automatic power changes after $LOGIND_IDLE_SECS.")
  fi

  tmp="$(grep -Rhs '^[[:space:]]*Allow(Suspend|Hibernation|HybridSleep|SuspendThenHibernate)=' /etc/systemd/sleep.conf /etc/systemd/sleep.conf.d/*.conf 2>/dev/null || true)"
  if [[ -n "$tmp" ]]; then
    SLEEP_CONF_LIMITS="$(printf '%s' "$tmp" | tr '\n' '; ' | sed 's/; $//')"
    while IFS= read -r line; do
      [[ -n "$line" ]] && LIMITATIONS+=("sleep.conf override present: $line")
    done <<< "$tmp"
  fi

  GRUB_CONSOLEBLANK="$(grep -Eo 'consoleblank=[^" ]+' /etc/default/grub 2>/dev/null | head -n1 || true)"
  [[ -n "$GRUB_CONSOLEBLANK" ]] || GRUB_CONSOLEBLANK="not explicitly set"

  rtc_alarm="$(cat /sys/class/rtc/rtc0/wakealarm 2>/dev/null || true)"
  if [[ -n "$rtc_alarm" && "$rtc_alarm" != "0" ]]; then
    TIMER_LINES+=("- rtc0 wakealarm is set to: $rtc_alarm")
    LIMITATIONS+=("An RTC wake alarm is already configured and may cause unexpected wake events.")
  fi

  tmp="$(systemctl list-timers --all --no-pager 2>/dev/null | grep -Ei 'sleep|suspend|hibernate|wake|power' || true)"
  if [[ -n "$tmp" ]]; then
    RELEVANT_TIMER_SUMMARY="$(printf '%s\n' "$tmp" | awk 'NR<=8 {print $0}' | tr '\n' '; ' | sed 's/; $//')"
    while IFS= read -r line; do
      [[ -n "$line" ]] && TIMER_LINES+=("- $line")
    done <<< "$(printf '%s\n' "$tmp" | awk 'NR<=8')"
  fi

  if have_cmd systemd-inhibit; then
    tmp="$(systemd-inhibit --list 2>/dev/null | awk 'NR>1 && NF' | head -n 8 || true)"
    if [[ -n "$tmp" ]]; then
      inhibitors_count="$(printf '%s\n' "$tmp" | wc -l | tr -d ' ')"
      INHIBITOR_SUMMARY="$inhibitors_count inhibitor(s) detected"
      LIMITATIONS+=("Active systemd inhibitors are present and may block or delay sleep.")
    fi
  fi

  if have_cmd pveversion; then
    LIMITATIONS+=("If this node is hosting running guests, suspend can disrupt VMs, containers, storage, clustering, and HA behavior.")
  fi
}

parse_recommended_packages() {
  local cpu_vendor_lc wifi_vendor=""
  cpu_vendor_lc="$(to_lower "$CPU_VENDOR")"

  if [[ "$HAS_BATTERY" == "yes" || "$HAS_LID" == "yes" ]]; then
    recommend_package acpi "battery and lid status reporting"
    recommend_package upower "battery reporting and power policy visibility"
  fi

  recommend_package ethtool "Wake-on-LAN inspection and configuration"

  if printf '%s\n' "${NETWORK_LINES[@]:-}" | grep -qi '(wifi'; then
    recommend_package iw "wireless capability and WoWLAN inspection"
    recommend_package wireless-regdb "wireless regulatory database"
    recommend_package wpasupplicant "Wi-Fi fallback authentication"
    recommend_package isc-dhcp-client "Wi-Fi fallback DHCP client"
  fi

  if [[ "$cpu_vendor_lc" == *intel* ]]; then
    recommend_package intel-microcode "Intel CPU microcode updates"
  elif [[ "$cpu_vendor_lc" == *amd* ]]; then
    recommend_package amd64-microcode "AMD CPU microcode updates"
  fi

  if have_cmd lspci; then
    if lspci 2>/dev/null | grep -Eiq 'network.*intel|wireless.*intel'; then
      wifi_vendor="intel"
    elif lspci 2>/dev/null | grep -Eiq 'network.*realtek|wireless.*realtek'; then
      wifi_vendor="realtek"
    elif lspci 2>/dev/null | grep -Eiq 'network.*broadcom|wireless.*broadcom'; then
      wifi_vendor="broadcom"
    fi
  fi

  case "$wifi_vendor" in
    intel)
      recommend_package firmware-iwlwifi "Intel wireless firmware"
      ;;
    realtek)
      recommend_package firmware-realtek "Realtek wireless/ethernet firmware"
      ;;
    broadcom)
      recommend_package firmware-brcm80211 "Broadcom wireless firmware"
      ;;
  esac
}

render_report() {
  REPORT_LINES+=("pve-sleep capability report")
  REPORT_LINES+=("Generated: $(date -Is 2>/dev/null || date)")
  REPORT_LINES+=("Host: $HOSTNAME_VAL | Kernel: $KERNEL_VAL | Arch: $ARCH_VAL")
  REPORT_LINES+=("OS: $DISTRO_VAL | Debian: $DEBIAN_VER ($DEBIAN_CODENAME) | Proxmox: $PVE_VERSION_RAW")
  REPORT_LINES+=("")

  REPORT_LINES+=("Hardware and platform checks")
  REPORT_LINES+=("$(mark "$CPU_GOVERNOR_PRESENT") CPU governors detected: ${CPU_GOVERNORS:-none exposed}")
  REPORT_LINES+=("$(mark "$CPU_POWERSAVE") CPU powersave mode available")
  REPORT_LINES+=("$(mark "$CPU_PERFORMANCE") CPU performance mode available")
  REPORT_LINES+=("$(mark "$GPU_CONTROL_PRESENT") GPU power controls detected: $GPU_CONTROL_SUMMARY")
  REPORT_LINES+=("$(mark "$HAS_LID") Lid switch detected")
  REPORT_LINES+=("$(mark "$HAS_DISPLAY") Display detected: $DISPLAY_SUMMARY")
  REPORT_LINES+=("$(mark "$HAS_BUILTIN_DISPLAY") Built-in display detected")
  REPORT_LINES+=("$(mark "$HAS_BATTERY") Battery detected: $BATTERY_SUMMARY")
  REPORT_LINES+=("")

  REPORT_LINES+=("Network and wake sources")
  REPORT_LINES+=("$( [[ $WOL_SUPPORTED_TOTAL -gt 0 ]] && echo "$CHECK" || echo "$CROSS" ) Wake-on-LAN support detected on $WOL_SUPPORTED_TOTAL adapter(s)")
  REPORT_LINES+=("$( [[ $WOWLAN_SUPPORTED_TOTAL -gt 0 ]] && echo "$CHECK" || echo "$CROSS" ) Wake-on-Wireless-LAN support detected on $WOWLAN_SUPPORTED_TOTAL adapter(s)")
  REPORT_LINES+=("$( [[ $USB_WAKE_CAPABLE_TOTAL -gt 0 ]] && echo "$CHECK" || echo "$CROSS" ) USB wake-capable devices detected: $USB_WAKE_CAPABLE_TOTAL (enabled: $USB_WAKE_ENABLED_TOTAL)")
  REPORT_LINES+=("$(mark "$RTC_WAKE_SUPPORTED") RTC wake alarm interface detected")
  REPORT_LINES+=("$( [[ -n "$SUPPORTED_WAKE_SUMMARY" && "$SUPPORTED_WAKE_SUMMARY" != "none detected" ]] && echo "$CHECK" || echo "$CROSS" ) Supported wake modes: $SUPPORTED_WAKE_SUMMARY")
  if ((${#NETWORK_LINES[@]} > 0)); then
    REPORT_LINES+=("Actual physical network adapters:")
    REPORT_LINES+=("${NETWORK_LINES[@]}")
  else
    REPORT_LINES+=("$CROSS No physical ethernet or Wi-Fi adapters were detected")
  fi
  REPORT_LINES+=("")

  REPORT_LINES+=("USB devices")
  if ((${#USB_LINES[@]} > 0)); then
    REPORT_LINES+=("${USB_LINES[@]}")
  else
    REPORT_LINES+=("$CROSS No USB devices were enumerated")
  fi
  REPORT_LINES+=("")

  REPORT_LINES+=("Sleep support")
  REPORT_LINES+=("$( [[ "$SUPPORTED_SLEEP_STATES" != "unknown" ]] && echo "$CHECK" || echo "$CROSS" ) Supported sleep states: $SUPPORTED_SLEEP_STATES")
  REPORT_LINES+=("$( [[ "$SUPPORTED_MEM_SLEEP" != "unknown" ]] && echo "$CHECK" || echo "$CROSS" ) Supported mem sleep modes: $SUPPORTED_MEM_SLEEP")
  REPORT_LINES+=("")

  REPORT_LINES+=("Configuration and services affecting sleep or wake")
  REPORT_LINES+=("- logind HandleLidSwitch=$LOGIND_LID")
  REPORT_LINES+=("- logind IdleAction=$LOGIND_IDLE_ACTION IdleActionSec=$LOGIND_IDLE_SECS")
  REPORT_LINES+=("- sleep.conf limits: $SLEEP_CONF_LIMITS")
  REPORT_LINES+=("- grub console blank: $GRUB_CONSOLEBLANK")
  REPORT_LINES+=("- relevant timers: $RELEVANT_TIMER_SUMMARY")
  REPORT_LINES+=("- inhibitors: $INHIBITOR_SUMMARY")
  if ((${#SERVICE_LINES[@]} > 0)); then
    REPORT_LINES+=("${SERVICE_LINES[@]}")
  fi
  if ((${#TIMER_LINES[@]} > 0)); then
    REPORT_LINES+=("Relevant timer details:")
    REPORT_LINES+=("${TIMER_LINES[@]}")
  fi
  REPORT_LINES+=("")

  REPORT_LINES+=("Needed packages")
  if ((${#NEEDED_PACKAGES[@]} > 0)); then
    local pkg
    for pkg in "${NEEDED_PACKAGES[@]}"; do
      REPORT_LINES+=("- $pkg")
    done
  else
    REPORT_LINES+=("$CHECK No additional packages are currently required based on this detection pass")
  fi
  REPORT_LINES+=("")

  REPORT_LINES+=("Packages not found or not determinable")
  if ((${#MISSING_PACKAGES[@]} > 0)); then
    local pkg
    for pkg in "${MISSING_PACKAGES[@]}"; do
      REPORT_LINES+=("- $pkg")
    done
  else
    REPORT_LINES+=("$CHECK All checked package names were resolvable through apt-cache")
  fi
  REPORT_LINES+=("")

  REPORT_LINES+=("Limitations and caveats")
  if ((${#LIMITATIONS[@]} > 0)); then
    local item
    for item in "${LIMITATIONS[@]}"; do
      REPORT_LINES+=("$WARN $item")
    done
  else
    REPORT_LINES+=("$CHECK No obvious blockers were detected in the current configuration snapshot")
  fi
}

write_outputs() {
  printf '%s\n' "${REPORT_LINES[@]}" | tee "$TXT_OUT"

  cat > "$JSON_OUT" <<EOF
{
  "meta": {
    "tool": "pve-sleep",
    "version": "$(json_escape "$VERSION")",
    "generated_at": "$(json_escape "$(date -Is 2>/dev/null || date)")"
  },
  "system": {
    "hostname": "$(json_escape "$HOSTNAME_VAL")",
    "kernel": "$(json_escape "$KERNEL_VAL")",
    "arch": "$(json_escape "$ARCH_VAL")",
    "os": "$(json_escape "$DISTRO_VAL")",
    "debian_version": "$(json_escape "$DEBIAN_VER")",
    "debian_codename": "$(json_escape "$DEBIAN_CODENAME")",
    "proxmox_version": "$(json_escape "$PVE_VERSION_RAW")",
    "proxmox_major": "$(json_escape "$PVE_MAJOR")"
  },
  "hardware": {
    "cpu_vendor": "$(json_escape "$CPU_VENDOR")",
    "cpu_governors": "$(json_escape "$CPU_GOVERNORS")",
    "cpu_governor_present": "$(json_escape "$CPU_GOVERNOR_PRESENT")",
    "cpu_powersave": "$(json_escape "$CPU_POWERSAVE")",
    "cpu_performance": "$(json_escape "$CPU_PERFORMANCE")",
    "gpu_control_present": "$(json_escape "$GPU_CONTROL_PRESENT")",
    "gpu_control_summary": "$(json_escape "$GPU_CONTROL_SUMMARY")",
    "lid_switch": "$(json_escape "$HAS_LID")",
    "display_detected": "$(json_escape "$HAS_DISPLAY")",
    "built_in_display": "$(json_escape "$HAS_BUILTIN_DISPLAY")",
    "display_summary": "$(json_escape "$DISPLAY_SUMMARY")",
    "battery_detected": "$(json_escape "$HAS_BATTERY")",
    "battery_summary": "$(json_escape "$BATTERY_SUMMARY")"
  },
  "sleep": {
    "supported_sleep_states": "$(json_escape "$SUPPORTED_SLEEP_STATES")",
    "supported_mem_sleep": "$(json_escape "$SUPPORTED_MEM_SLEEP")"
  },
  "wake": {
    "wol_supported_total": $WOL_SUPPORTED_TOTAL,
    "wowlan_supported_total": $WOWLAN_SUPPORTED_TOTAL,
    "usb_wake_capable_total": $USB_WAKE_CAPABLE_TOTAL,
    "usb_wake_enabled_total": $USB_WAKE_ENABLED_TOTAL,
    "rtc_wake_supported": "$(json_escape "$RTC_WAKE_SUPPORTED")",
    "supported_wake_modes": "$(json_escape "$SUPPORTED_WAKE_SUMMARY")"
  },
  "network_adapters": $(json_raw_array NETWORK_JSON),
  "usb_devices": $(json_raw_array USB_JSON),
  "config": {
    "logind_lid_switch": "$(json_escape "$LOGIND_LID")",
    "logind_idle_action": "$(json_escape "$LOGIND_IDLE_ACTION")",
    "logind_idle_action_sec": "$(json_escape "$LOGIND_IDLE_SECS")",
    "sleep_conf_limits": "$(json_escape "$SLEEP_CONF_LIMITS")",
    "grub_consoleblank": "$(json_escape "$GRUB_CONSOLEBLANK")",
    "relevant_timer_summary": "$(json_escape "$RELEVANT_TIMER_SUMMARY")",
    "inhibitor_summary": "$(json_escape "$INHIBITOR_SUMMARY")"
  },
  "needed_packages": $(json_string_array NEEDED_PACKAGES),
  "missing_packages": $(json_string_array MISSING_PACKAGES),
  "limitations": $(json_string_array LIMITATIONS)
}
EOF
}

copy_report_snapshot() {
  local suffix="$1"
  cp -f "$TXT_OUT" "$OUTPUT_DIR/sleep-system-$suffix.txt"
  cp -f "$JSON_OUT" "$OUTPUT_DIR/sleep-system-$suffix.json"
}

append_runtime_note() {
  local line="$1"
  printf '%s\n' "$line" | tee -a "$TXT_OUT"
}

enable_wake_features() {
  if have_cmd nw_enable_supported_wake_adapters; then
    if nw_enable_supported_wake_adapters; then
      append_runtime_note "$CHECK Enabled supported Wake-on-LAN and Wake-on-Wireless-LAN settings where possible"
    else
      append_runtime_note "$WARN No additional network wake settings could be enabled automatically"
    fi
  else
    append_runtime_note "$WARN Network wake helper functions are unavailable"
  fi
}

configure_wifi_interactively() {
  local wifi_iface="" eth_iface="" ssid="" passphrase=""

  if ! have_cmd nw_first_wifi_iface; then
    append_runtime_note "$WARN Wi-Fi helper functions are unavailable"
    return 0
  fi

  wifi_iface="$(nw_first_wifi_iface || true)"
  eth_iface="$(nw_first_ethernet_iface || true)"

  if [[ -z "$wifi_iface" ]]; then
    append_runtime_note "$WARN No Wi-Fi interface was detected; Wi-Fi fallback was not configured"
    return 0
  fi

  ssid="$(nw_prompt_wifi_network "$wifi_iface" 5 || true)"
  if [[ -z "$ssid" ]]; then
    append_runtime_note "$WARN Wi-Fi fallback configuration was skipped"
    return 0
  fi

  if [[ -t 0 ]]; then
    read -r -s -p "Enter the passphrase for Wi-Fi network \"$ssid\" (leave blank for open network): " passphrase
    echo
  fi

  nw_configure_wpa_supplicant "$wifi_iface" "$ssid" "$passphrase" >/dev/null
  append_runtime_note "$CHECK Configured wpa_supplicant for $wifi_iface using SSID $ssid"
  append_runtime_note "$WARN Wi-Fi cannot be bridged into a Proxmox bridge without a VPN or routed setup"

  if [[ -n "$eth_iface" ]]; then
    if have_cmd systemctl; then
      systemctl enable --now pve-network-failover.service >/dev/null 2>&1 || true
    fi
    append_runtime_note "$CHECK Ethernet and Wi-Fi are both present; Wi-Fi failover is configured and ethernet remains preferred when available"
  else
    nw_start_wifi_failover "$wifi_iface" || true
    append_runtime_note "$CHECK Configured Wi-Fi as the active uplink because no ethernet interface was detected"
  fi
}

main() {
  parse_proxmox
  parse_cpu_and_gpu
  parse_lid_display_battery
  parse_network
  parse_usb
  parse_sleep_and_wake
  parse_power_configs
  parse_recommended_packages
  render_report
  write_outputs

  if ((INSTALL_MISSING == 1 && POST_INSTALL == 0)); then
    copy_report_snapshot before
    if have_cmd prompt_and_install_packages && (( ${#NEEDED_PACKAGE_NAMES[@]} > 0 )); then
      prompt_and_install_packages "${NEEDED_PACKAGE_NAMES[@]}"
      case $? in
        10)
          local -a rerun_args=()
          ((PROBE_WRITE == 1)) && rerun_args+=(--probe-write)
          ((ENABLE_WAKE == 1)) && rerun_args+=(--enable-wake)
          ((CONFIGURE_WIFI == 1)) && rerun_args+=(--configure-wifi)
          rerun_args+=(--post-install --output-dir "$OUTPUT_DIR")
          exec "$0" "${rerun_args[@]}"
          ;;
        11)
          append_runtime_note "$WARN Additional packages were identified but installation was skipped"
          ;;
        12)
          append_runtime_note "$CROSS Additional packages were identified but installation failed or was deemed unsafe"
          ;;
      esac
    fi
  fi

  if ((ENABLE_WAKE == 1)); then
    enable_wake_features
  fi

  if ((CONFIGURE_WIFI == 1)); then
    configure_wifi_interactively
  fi

  if ((POST_INSTALL == 1)); then
    copy_report_snapshot after
  fi
}

main "$@"
