#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/pve-sleep"
STATE_FILE="$STATE_DIR/safe-sleep.state"
mkdir -p "$STATE_DIR"

log() {
  echo "[safe-sleep] $*"
  command -v logger >/dev/null 2>&1 && logger -t pve-safe-sleep -- "$*" || true
}

list_running_vms() {
  command -v qm >/dev/null 2>&1 || return 0
  qm list 2>/dev/null | awk 'NR>1 && $3 == "running" {print $1}'
}

list_running_cts() {
  command -v pct >/dev/null 2>&1 || return 0
  pct list 2>/dev/null | awk 'NR>1 && $2 == "running" {print $1}'
}

prepare_vm() {
  local vmid="$1"
  local snap
  snap="pve-sleep-$(date +%Y%m%d-%H%M%S)"

  if qm suspend "$vmid" --todisk 0 >/dev/null 2>&1; then
    echo "vm:$vmid:suspend" >> "$STATE_FILE"
    log "Suspended VM $vmid"
    return 0
  fi

  qm snapshot "$vmid" "$snap" >/dev/null 2>&1 || true
  if qm shutdown "$vmid" --timeout 60 >/dev/null 2>&1 || qm stop "$vmid" >/dev/null 2>&1; then
    echo "vm:$vmid:start" >> "$STATE_FILE"
    log "Snapshotted and stopped VM $vmid"
  fi
}

prepare_ct() {
  local ctid="$1"
  local snap
  snap="pve-sleep-$(date +%Y%m%d-%H%M%S)"

  if pct suspend "$ctid" >/dev/null 2>&1; then
    echo "ct:$ctid:resume" >> "$STATE_FILE"
    log "Suspended container $ctid"
    return 0
  fi

  pct snapshot "$ctid" "$snap" >/dev/null 2>&1 || true
  if pct shutdown "$ctid" --timeout 60 >/dev/null 2>&1 || pct stop "$ctid" >/dev/null 2>&1; then
    echo "ct:$ctid:start" >> "$STATE_FILE"
    log "Snapshotted and stopped container $ctid"
  fi
}

prepare_all() {
  : > "$STATE_FILE"
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] && prepare_vm "$id"
  done < <(list_running_vms)

  while IFS= read -r id; do
    [[ -n "$id" ]] && prepare_ct "$id"
  done < <(list_running_cts)

  log "Guest preparation completed. Host sleep is intentionally not triggered here."
}

restore_all() {
  [[ -f "$STATE_FILE" ]] || { log "No previous state file found"; return 0; }
  local type id action
  while IFS=: read -r type id action; do
    case "$type:$action" in
      vm:start)
        qm start "$id" >/dev/null 2>&1 || true
        ;;
      vm:suspend)
        qm resume "$id" >/dev/null 2>&1 || true
        ;;
      ct:start)
        pct start "$id" >/dev/null 2>&1 || true
        ;;
      ct:resume)
        pct resume "$id" >/dev/null 2>&1 || true
        ;;
    esac
  done < "$STATE_FILE"
  log "Guest restore completed"
}

status() {
  echo "Running VMs:"
  list_running_vms || true
  echo
  echo "Running containers:"
  list_running_cts || true
}

# Verify WoL or WoWLAN is active on at least one adapter before sleeping
verify_wake_before_sleep() {
  local iface path wol_mode
  for path in /sys/class/net/*; do
    iface="$(basename "$path")"
    [[ -e "$path/device" ]] || continue
    case "$iface" in lo|vmbr*|veth*|tap*|fwln*|fwbr*|fwpr*|docker*|virbr*|br-*|vnet*) continue ;; esac

    if [[ -d "$path/wireless" ]]; then
      if command -v iw >/dev/null 2>&1; then
        local phy
        phy="$(iw dev "$iface" info 2>/dev/null | awk '/wiphy/ {print "phy"$2; exit}')"
        [[ -n "$phy" ]] && iw phy "$phy" wowlan show 2>/dev/null | grep -q 'enabled' && return 0
      fi
    else
      if command -v ethtool >/dev/null 2>&1; then
        wol_mode="$(ethtool "$iface" 2>/dev/null | awk -F': ' '/^\s*Wake-on:/ {print $2; exit}')"
        [[ -n "$wol_mode" && "$wol_mode" != "d" ]] && return 0
      fi
    fi
  done
  return 1
}

# Verify sleep mode is WoL-compatible (S3 mem or s2idle)
verify_sleep_mode() {
  local modes
  [[ -r /sys/power/mem_sleep ]] || return 1
  modes="$(cat /sys/power/mem_sleep 2>/dev/null)"
  # Accept s2idle or deep (S3)
  [[ "$modes" == *"s2idle"* || "$modes" == *"deep"* ]]
}

do_sleep() {
  log "Verifying wake capability before sleep..."
  if ! verify_wake_before_sleep; then
    log "ERROR: No WoL or WoWLAN active on any adapter. Refusing to sleep."
    exit 1
  fi
  if ! verify_sleep_mode; then
    log "ERROR: No compatible sleep mode (s2idle/S3) available. Refusing to sleep."
    exit 1
  fi

  log "Preparing guests for sleep..."
  prepare_all

  log "Triggering host suspend..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl suspend
  else
    echo mem > /sys/power/state
  fi

  # After wake
  log "Host resumed from sleep. Restoring guests..."
  restore_all
  log "Sleep/wake cycle complete."
}

case "${1:-status}" in
  prepare)
    prepare_all
    ;;
  restore)
    restore_all
    ;;
  sleep)
    do_sleep
    ;;
  status)
    status
    ;;
  *)
    echo "Usage: $0 {prepare|restore|sleep|status}" >&2
    exit 1
    ;;
esac
