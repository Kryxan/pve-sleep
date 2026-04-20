#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/network.sh"

STATE_FILE="${NW_STATE_DIR}/network-failover.state"
mkdir -p "$NW_STATE_DIR" "$NW_RUN_DIR"


ETH_IFACE="${PVE_SLEEP_ETH_IFACE:-$(nw_first_ethernet_iface || true)}"
WIFI_IFACE="${PVE_SLEEP_WIFI_IFACE:-$(nw_first_wifi_iface || true)}"
CHECK_INTERVAL="${PVE_SLEEP_NET_CHECK_INTERVAL:-30}"

save_state() {
  cat > "$STATE_FILE" <<EOF
ETH_IFACE=${ETH_IFACE}
WIFI_IFACE=${WIFI_IFACE}
EOF
}

eth_has_carrier() {
  [[ -n "$ETH_IFACE" && -r "/sys/class/net/$ETH_IFACE/carrier" ]] && [[ "$(cat "/sys/class/net/$ETH_IFACE/carrier" 2>/dev/null)" == "1" ]]
}

main_loop() {
  nw_log "Network failover monitor started: ethernet=${ETH_IFACE:-none} wifi=${WIFI_IFACE:-none} (Wi-Fi always connected, metric 200)"

  # Always keep Wi-Fi up and connected if configured
  if [[ -n "$WIFI_IFACE" ]]; then
    nw_start_wifi_failover "$WIFI_IFACE" || true
    nw_log "Ensured Wi-Fi ($WIFI_IFACE) is connected and has DHCP lease."
  fi

  while true; do
    if eth_has_carrier; then
      nw_log "Ethernet ($ETH_IFACE) is UP. Default route should be via Ethernet (metric 100). Wi-Fi remains connected as backup (metric 200)."
    else
      nw_log "Ethernet ($ETH_IFACE) is DOWN. Default route should be via Wi-Fi (metric 200)."
    fi
    save_state
    sleep "$CHECK_INTERVAL"
  done
}

main_loop
