#!/usr/bin/env bash
set -u

NW_STATE_DIR="${NW_STATE_DIR:-/var/lib/pve-sleep}"
NW_RUN_DIR="${NW_RUN_DIR:-/run/pve-sleep}"

nw_have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

nw_log() {
  echo "[networkwake] $*"
  if nw_have_cmd logger; then
    logger -t pve-sleep-network -- "$*" || true
  fi
}

nw_is_physical_iface() {
  local iface="$1"
  [[ -e "/sys/class/net/$iface/device" ]] || return 1
  case "$iface" in
    lo|vmbr*|veth*|tap*|fwln*|fwbr*|fwpr*|docker*|virbr*|br-*|vnet*)
      return 1
      ;;
  esac
  return 0
}

nw_is_wifi_iface() {
  local iface="$1"
  [[ -d "/sys/class/net/$iface/wireless" ]]
}

nw_iface_type() {
  local iface="$1"
  if nw_is_wifi_iface "$iface"; then
    printf '%s' "wifi"
  else
    printf '%s' "ethernet"
  fi
}

nw_list_physical_ifaces() {
  local path iface
  for path in /sys/class/net/*; do
    iface="$(basename "$path")"
    nw_is_physical_iface "$iface" && echo "$iface"
  done
}

nw_first_wifi_iface() {
  local iface
  while IFS= read -r iface; do
    if nw_is_wifi_iface "$iface"; then
      echo "$iface"
      return 0
    fi
  done < <(nw_list_physical_ifaces)
  return 1
}

nw_first_ethernet_iface() {
  local iface
  while IFS= read -r iface; do
    if ! nw_is_wifi_iface "$iface"; then
      echo "$iface"
      return 0
    fi
  done < <(nw_list_physical_ifaces)
  return 1
}

nw_get_wol_support() {
  local iface="$1"
  local out=""
  if nw_have_cmd ethtool; then
    out="$(ethtool "$iface" 2>/dev/null || true)"
    awk -F': ' '/Supports Wake-on:/ {print $2; exit}' <<< "$out"
  fi
}

nw_get_wol_current() {
  local iface="$1"
  local out=""
  if nw_have_cmd ethtool; then
    out="$(ethtool "$iface" 2>/dev/null || true)"
    awk -F': ' '/Wake-on:/ {print $2; exit}' <<< "$out"
  fi
}

nw_get_wowlan_support() {
  local iface="$1"
  local phy phyinfo
  nw_is_wifi_iface "$iface" || return 1
  nw_have_cmd iw || return 1
  phy="$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/ {print "phy"$2; exit}')"
  [[ -n "$phy" ]] || return 1
  phyinfo="$(iw phy "$phy" info 2>/dev/null || true)"
  if grep -q 'WoWLAN support' <<< "$phyinfo"; then
    echo yes
    return 0
  fi
  return 1
}

nw_enable_wol() {
  local iface="$1"
  local support mode
  nw_have_cmd ethtool || return 1
  support="$(nw_get_wol_support "$iface")"
  [[ -n "$support" ]] || return 1
  [[ "$support" != "d" ]] || return 1

  if [[ "$support" == *g* ]]; then
    mode="g"
  else
    mode="$(printf '%s' "$support" | sed 's/d//g' | cut -c1)"
  fi

  [[ -n "$mode" ]] || return 1
  ethtool -s "$iface" wol "$mode" >/dev/null 2>&1
}

nw_enable_wowlan() {
  local iface="$1"
  local phy
  nw_is_wifi_iface "$iface" || return 1
  nw_have_cmd iw || return 1
  phy="$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/ {print "phy"$2; exit}')"
  [[ -n "$phy" ]] || return 1
  iw phy "$phy" wowlan enable any >/dev/null 2>&1
}

nw_enable_supported_wake_adapters() {
  local iface type enabled_any=1
  while IFS= read -r iface; do
    type="$(nw_iface_type "$iface")"
    if [[ "$type" == "ethernet" ]]; then
      if nw_enable_wol "$iface"; then
        nw_log "Enabled Wake-on-LAN on $iface"
        enabled_any=0
      fi
    else
      if nw_enable_wowlan "$iface"; then
        nw_log "Enabled Wake-on-Wireless-LAN on $iface"
        enabled_any=0
      fi
    fi
  done < <(nw_list_physical_ifaces)
  return $enabled_any
}

nw_scan_wifi_networks() {
  local iface="$1"
  local limit="${2:-5}"
  nw_is_wifi_iface "$iface" || return 1
  nw_have_cmd iw || return 1

  mkdir -p "$NW_RUN_DIR"
  ip link set "$iface" up >/dev/null 2>&1 || true

  iw dev "$iface" scan 2>/dev/null | awk '
    /^BSS / {sig="-999"; ssid=""}
    /signal:/ {sig=$2}
    /^[[:space:]]*SSID:/ {
      ssid=$0
      sub(/^[[:space:]]*SSID:[[:space:]]*/, "", ssid)
      if (ssid == "") ssid="[hidden]"
      print sig "|" ssid
    }
  ' | sort -t'|' -k1,1nr | awk -F'|' '!seen[$2]++' | head -n "$limit"
}

nw_prompt_wifi_network() {
  local iface="$1"
  local limit="${2:-5}"
  local networks=()
  local line choice default_choice=1 selected

  while IFS= read -r line; do
    [[ -n "$line" ]] && networks+=("$line")
  done < <(nw_scan_wifi_networks "$iface" "$limit")

  if [[ ${#networks[@]} -eq 0 ]]; then
    echo ""
    return 1
  fi

  echo "Available Wi-Fi networks on $iface (top ${#networks[@]} by signal):" >&2
  local idx=1
  for line in "${networks[@]}"; do
    echo "  $idx) ${line#*|}  [signal ${line%%|*} dBm]" >&2
    idx=$((idx + 1))
  done
  echo "  0) Skip Wi-Fi fallback configuration" >&2
  echo "Note: Wi-Fi cannot be bridged into a Proxmox bridge without a VPN or routed design." >&2

  if [[ -t 0 ]]; then
    read -r -p "Choose a Wi-Fi network [${default_choice}]: " choice
  else
    choice="$default_choice"
  fi
  choice="${choice:-$default_choice}"

  if [[ "$choice" == "0" ]]; then
    echo ""
    return 0
  fi

  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#networks[@]} )); then
    selected="${networks[$((choice - 1))]}"
    echo "${selected#*|}"
    return 0
  fi

  echo "${networks[0]#*|}"
}

nw_configure_wpa_supplicant() {
  local iface="$1"
  local ssid="$2"
  local passphrase="${3:-}"
  local conf_dir="/etc/wpa_supplicant"
  local conf_file="$conf_dir/wpa_supplicant-$iface.conf"

  mkdir -p "$conf_dir"
  chmod 0755 "$conf_dir"

  if [[ -n "$passphrase" ]]; then
    if nw_have_cmd wpa_passphrase; then
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
  echo "$conf_file"
}

nw_start_wifi_failover() {
  local iface="$1"
  local conf_file="/etc/wpa_supplicant/wpa_supplicant-$iface.conf"
  local pid_file="$NW_RUN_DIR/wpa-$iface.pid"

  [[ -f "$conf_file" ]] || return 1
  mkdir -p "$NW_RUN_DIR"
  ip link set "$iface" up >/dev/null 2>&1 || true

  if nw_have_cmd wpa_supplicant && [[ ! -f "$pid_file" ]]; then
    wpa_supplicant -B -i "$iface" -c "$conf_file" -P "$pid_file" >/dev/null 2>&1 || true
  fi

  if nw_have_cmd dhclient; then
    dhclient "$iface" >/dev/null 2>&1 || true
  fi
}

nw_stop_wifi_failover() {
  local iface="$1"
  local pid_file="$NW_RUN_DIR/wpa-$iface.pid"

  if nw_have_cmd dhclient; then
    dhclient -r "$iface" >/dev/null 2>&1 || true
  fi

  if [[ -f "$pid_file" ]]; then
    kill "$(cat "$pid_file" 2>/dev/null)" >/dev/null 2>&1 || true
    rm -f "$pid_file"
  fi
}
