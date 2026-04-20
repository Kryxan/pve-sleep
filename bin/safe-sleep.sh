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

case "${1:-status}" in
  prepare)
    prepare_all
    ;;
  restore)
    restore_all
    ;;
  status)
    status
    ;;
  *)
    echo "Usage: $0 {prepare|restore|status}" >&2
    exit 1
    ;;
esac
