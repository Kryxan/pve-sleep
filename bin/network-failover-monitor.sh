#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/networkwake.sh"

STATE_FILE="${NW_STATE_DIR}/network-failover.state"
mkdir -p "$NW_STATE_DIR" "$NW_RUN_DIR"

ETH_IFACE="${PVE_SLEEP_ETH_IFACE:-$(nw_first_ethernet_iface || true)}"
WIFI_IFACE="${PVE_SLEEP_WIFI_IFACE:-$(nw_first_wifi_iface || true)}"
CHECK_INTERVAL="${PVE_SLEEP_NET_CHECK_INTERVAL:-30}"

ETH_STABLE_COUNT=0
ETH_FAIL_COUNT=0
WIFI_FAILOVER_ACTIVE=0

save_state() {
  cat > "$STATE_FILE" <<EOF
ETH_IFACE=${ETH_IFACE}
WIFI_IFACE=${WIFI_IFACE}
ETH_STABLE_COUNT=${ETH_STABLE_COUNT}
ETH_FAIL_COUNT=${ETH_FAIL_COUNT}
WIFI_FAILOVER_ACTIVE=${WIFI_FAILOVER_ACTIVE}
EOF
}

eth_has_carrier() {
  [[ -n "$ETH_IFACE" && -r "/sys/class/net/$ETH_IFACE/carrier" ]] && [[ "$(cat "/sys/class/net/$ETH_IFACE/carrier" 2>/dev/null)" == "1" ]]
}

main_loop() {
  nw_log "Network failover monitor started: ethernet=${ETH_IFACE:-none} wifi=${WIFI_IFACE:-none}"

  while true; do
    if eth_has_carrier; then
      ETH_STABLE_COUNT=$((ETH_STABLE_COUNT + 1))
      if ((WIFI_FAILOVER_ACTIVE == 1 && ETH_STABLE_COUNT >= 3)); then
        nw_stop_wifi_failover "$WIFI_IFACE" || true
        WIFI_FAILOVER_ACTIVE=0
        nw_log "Ethernet is stable again on $ETH_IFACE; switching back from Wi-Fi failover"
      fi
    else
      ETH_STABLE_COUNT=0
      ETH_FAIL_COUNT=$((ETH_FAIL_COUNT + 1))
      if [[ -n "$WIFI_IFACE" ]]; then
        nw_start_wifi_failover "$WIFI_IFACE" || true
        WIFI_FAILOVER_ACTIVE=1
        nw_log "Ethernet is unavailable; enabling Wi-Fi failover on $WIFI_IFACE"
      fi
    fi

    save_state
    sleep "$CHECK_INTERVAL"
  done
}

main_loop
