#!/usr/bin/env bash
# =============================================================================
# pve-sleep: network.sh — network interface helpers, WiFi, WoL/WoWLAN
# =============================================================================
set -u

NW_STATE_DIR="${NW_STATE_DIR:-/var/lib/pve-sleep}"
NW_RUN_DIR="${NW_RUN_DIR:-/run/pve-sleep}"

# ---------------------------------------------------------------------------
# Interface classification
# ---------------------------------------------------------------------------

nw_is_physical_iface() {
  local iface="$1"
  [[ -e "/sys/class/net/$iface/device" ]] || return 1
  case "$iface" in
    lo|vmbr*|veth*|tap*|fwln*|fwbr*|fwpr*|docker*|virbr*|br-*|vnet*) return 1 ;;
  esac
  return 0
}

nw_is_wifi_iface() {
  [[ -d "/sys/class/net/$1/wireless" ]]
}

nw_iface_type() {
  nw_is_wifi_iface "$1" && printf 'wifi' || printf 'ethernet'
}

nw_list_physical_ifaces() {
  local iface
  for iface in $(ls /sys/class/net 2>/dev/null); do
    nw_is_physical_iface "$iface" && echo "$iface"
  done
}

nw_first_wifi_iface() {
  local iface
  for iface in $(nw_list_physical_ifaces); do
    nw_is_wifi_iface "$iface" && echo "$iface" && return 0
  done
  return 1
}

nw_first_ethernet_iface() {
  local iface
  for iface in $(nw_list_physical_ifaces); do
    nw_is_wifi_iface "$iface" || { echo "$iface"; return 0; }
  done
  return 1
}

# Check if an ethernet interface is used by a Proxmox bridge
nw_iface_is_bridged() {
  local iface="$1"
  local br
  for br in /sys/class/net/vmbr*/brif/"$iface"; do
    [[ -e "$br" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# WoL / WoWLAN detection
# ---------------------------------------------------------------------------

nw_get_wol_support() {
  local iface="$1"
  have_cmd ethtool || return 1
  ethtool "$iface" 2>/dev/null | awk -F': ' '/Supports Wake-on:/ {print $2; exit}'
}

nw_get_wol_current() {
  local iface="$1"
  have_cmd ethtool || return 1
  ethtool "$iface" 2>/dev/null | awk -F': ' '/^[[:space:]]*Wake-on:/ {print $2; exit}'
}

nw_get_wowlan_support() {
  local iface="$1"
  nw_is_wifi_iface "$iface" || return 1
  have_cmd iw || return 1
  local phy
  phy="$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/ {print "phy"$2; exit}')"
  [[ -n "$phy" ]] || return 1
  iw phy "$phy" info 2>/dev/null | grep -q 'WoWLAN support'
}

# ---------------------------------------------------------------------------
# WoL / WoWLAN enable
# ---------------------------------------------------------------------------

nw_enable_wol() {
  local iface="$1"
  have_cmd ethtool || return 1
  local support mode
  support="$(nw_get_wol_support "$iface" 2>/dev/null || true)"
  [[ -n "$support" && "$support" != "d" ]] || return 1
  if [[ "$support" == *g* ]]; then mode="g"
  else mode="$(printf '%s' "$support" | sed 's/d//g' | cut -c1)"; fi
  [[ -n "$mode" ]] || return 1
  ethtool -s "$iface" wol "$mode" >/dev/null 2>&1
}

nw_enable_wowlan() {
  local iface="$1"
  nw_is_wifi_iface "$iface" || return 1
  have_cmd iw || return 1
  local phy
  phy="$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/ {print "phy"$2; exit}')"
  [[ -n "$phy" ]] || return 1
  iw phy "$phy" wowlan enable any >/dev/null 2>&1
}

nw_enable_all_wake_adapters() {
  local iface enabled_any=1
  for iface in $(nw_list_physical_ifaces); do
    if nw_is_wifi_iface "$iface"; then
      nw_enable_wowlan "$iface" && { log "Enabled WoWLAN on $iface"; enabled_any=0; }
    else
      nw_enable_wol "$iface" && { log "Enabled WoL on $iface"; enabled_any=0; }
    fi
  done
  return $enabled_any
}

# ---------------------------------------------------------------------------
# USB wake
# ---------------------------------------------------------------------------

nw_enable_usb_wake_all() {
  local count=0 wakeup
  for wakeup in /sys/bus/usb/devices/*/power/wakeup; do
    [[ -w "$wakeup" ]] || continue
    echo "enabled" > "$wakeup" 2>/dev/null && count=$((count + 1))
  done
  log "Enabled USB wake on $count device(s)."
  (( count > 0 ))
}

nw_set_network_power_for_wake() {
  local ctrl
  for ctrl in /sys/class/net/*/device/power/control; do
    [[ -w "$ctrl" ]] && echo "on" > "$ctrl" 2>/dev/null || true
  done
}

# ---------------------------------------------------------------------------
# WiFi scanning
# ---------------------------------------------------------------------------

nw_scan_wifi_networks() {
  local iface="$1" limit="${2:-5}"
  nw_is_wifi_iface "$iface" || return 1
  have_cmd iw || return 1
  mkdir -p "$NW_RUN_DIR"
  ip link set "$iface" up >/dev/null 2>&1 || true
  iw dev "$iface" scan 2>/dev/null | awk '
    /^BSS / {sig="-999"; ssid=""}
    /signal:/ {sig=$2}
    /^[[:space:]]*SSID:/ {
      ssid=$0; sub(/^[[:space:]]*SSID:[[:space:]]*/, "", ssid)
      if (ssid == "") ssid="[hidden]"
      print sig "|" ssid
    }
  ' | sort -t'|' -k1,1nr | awk -F'|' '!seen[$2]++' | head -n "$limit"
}

nw_prompt_wifi_network() {
  local iface="$1" limit="${2:-5}"
  local -a networks=()
  local line

  while IFS= read -r line; do
    [[ -n "$line" ]] && networks+=("$line")
  done < <(nw_scan_wifi_networks "$iface" "$limit")

  if (( ${#networks[@]} == 0 )); then
    echo ""; return 1
  fi

  echo "Available Wi-Fi networks on $iface (top ${#networks[@]} by signal):" >&2
  local idx=1
  for line in "${networks[@]}"; do
    echo "  $idx) ${line#*|}  [signal ${line%%|*} dBm]" >&2
    idx=$((idx + 1))
  done
  echo "  0) Skip Wi-Fi configuration" >&2

  local choice default_choice=1
  if [[ -t 0 ]]; then
    read -r -p "Choose a network [${default_choice}]: " choice
  else
    choice="$default_choice"
  fi
  choice="${choice:-$default_choice}"

  [[ "$choice" == "0" ]] && { echo ""; return 0; }

  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#networks[@]} )); then
    echo "${networks[$((choice - 1))]#*|}"
    return 0
  fi
  echo "${networks[0]#*|}"
}

# ---------------------------------------------------------------------------
# WPA supplicant configuration
# ---------------------------------------------------------------------------

nw_configure_wpa_supplicant() {
  local iface="$1" ssid="$2" passphrase="${3:-}"
  local conf_dir="/etc/wpa_supplicant"
  local conf_file="$conf_dir/wpa_supplicant-$iface.conf"

  [[ -n "$ssid" ]] || { err "SSID cannot be empty."; return 1; }

  mkdir -p "$conf_dir"
  chmod 0755 "$conf_dir"

  if [[ -n "$passphrase" ]]; then
    if have_cmd wpa_passphrase; then
      wpa_passphrase "$ssid" "$passphrase" > "$conf_file"
    else
      cat > "$conf_file" <<EOF
ctrl_interface=/run/wpa_supplicant
update_config=1
country=US
network={
    ssid="$ssid"
    psk="$passphrase"
}
EOF
    fi
  else
    cat > "$conf_file" <<EOF
ctrl_interface=/run/wpa_supplicant
update_config=1
country=US
network={
    ssid="$ssid"
    key_mgmt=NONE
}
EOF
  fi

  chmod 0600 "$conf_file"
  # Validate config has a network block
  grep -q 'network={' "$conf_file" || { err "wpa_supplicant config invalid."; return 1; }
  log "Generated $conf_file"
  echo "$conf_file"
}

# ---------------------------------------------------------------------------
# Network interface file generation (idempotent)
# ---------------------------------------------------------------------------

# Ensure source line exists in /etc/network/interfaces
nw_ensure_source_line() {
  local main="/etc/network/interfaces"
  local src_line="source /etc/network/interfaces.d/*"
  [[ -f "$main" ]] || touch "$main"
  if ! grep -qF "$src_line" "$main"; then
    echo "" >> "$main"
    echo "$src_line" >> "$main"
    log "Added source line to $main"
  fi
}

# Write /etc/network/interfaces.d/wifi-failover (idempotent — overwrites)
nw_write_wifi_failover_iface() {
  local iface="$1"
  local file="/etc/network/interfaces.d/wifi-failover"
  mkdir -p /etc/network/interfaces.d
  cat > "$file" <<EOF
# pve-sleep: Wi-Fi failover interface
# Metric 200 ensures Ethernet/bridge traffic is preferred
allow-hotplug $iface
iface $iface inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant-$iface.conf
    metric 200
EOF
  log "Wrote $file"
}

# Configure Ethernet metric in /etc/network/interfaces (only if not bridged)
nw_ensure_eth_metric() {
  local eth="$1"
  local main="/etc/network/interfaces"

  # If the interface is bridged by Proxmox, don't touch it — the bridge handles routing
  if nw_iface_is_bridged "$eth"; then
    log "Ethernet $eth is bridged (Proxmox) — not modifying its config."
    return 0
  fi

  # Check if metric is already set for this interface
  if grep -qE "^[[:space:]]*iface[[:space:]]+${eth}[[:space:]]" "$main" 2>/dev/null; then
    if grep -A5 "^[[:space:]]*iface[[:space:]]+${eth}[[:space:]]" "$main" | grep -q 'metric'; then
      return 0  # metric already configured
    fi
    # Add metric 100 after the iface line
    sed -i "/^[[:space:]]*iface[[:space:]]\+${eth}[[:space:]]\+inet[[:space:]]\+dhcp/a\\    metric 100" "$main" 2>/dev/null || true
    log "Added metric 100 to $eth in $main"
  fi
}

# Enable wpa_supplicant systemd service
nw_enable_wpa_service() {
  local iface="$1"
  if have_cmd systemctl; then
    systemctl enable "wpa_supplicant@${iface}.service" >/dev/null 2>&1 || true
    systemctl restart "wpa_supplicant@${iface}.service" >/dev/null 2>&1 || true
    log "Enabled wpa_supplicant@${iface}.service"
  fi
}

# ---------------------------------------------------------------------------
# WiFi failover daemon helpers
# ---------------------------------------------------------------------------

nw_start_wifi_failover() {
  local iface="$1"
  local conf_file="/etc/wpa_supplicant/wpa_supplicant-$iface.conf"
  local pid_file="$NW_RUN_DIR/wpa-$iface.pid"

  [[ -f "$conf_file" ]] || return 1
  mkdir -p "$NW_RUN_DIR"
  ip link set "$iface" up >/dev/null 2>&1 || true

  if have_cmd wpa_supplicant && [[ ! -f "$pid_file" ]]; then
    wpa_supplicant -B -i "$iface" -c "$conf_file" -P "$pid_file" >/dev/null 2>&1 || true
  fi
  if have_cmd dhclient; then
    dhclient "$iface" >/dev/null 2>&1 || true
  fi
}

nw_stop_wifi_failover() {
  local iface="$1"
  local pid_file="$NW_RUN_DIR/wpa-$iface.pid"

  if have_cmd dhclient; then
    dhclient -r "$iface" >/dev/null 2>&1 || true
  fi
  if [[ -f "$pid_file" ]]; then
    kill "$(cat "$pid_file" 2>/dev/null)" >/dev/null 2>&1 || true
    rm -f "$pid_file"
  fi
}

nw_log() {
  echo "[networkwake] $*"
  have_cmd logger && logger -t pve-sleep-network -- "$*" || true
}
