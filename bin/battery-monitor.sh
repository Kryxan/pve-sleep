#!/usr/bin/env bash
set -euo pipefail

LOW_BATTERY_PERCENT="${PVE_SLEEP_LOW_BATTERY_PERCENT:-15}"
CHECK_INTERVAL="${PVE_SLEEP_BATTERY_CHECK_INTERVAL:-60}"
STATE_DIR="/var/lib/pve-sleep"
REQUEST_FLAG="/run/pve-sleep/request-safe-sleep"
HOOK_SCRIPT="/opt/pve-sleep/hooks/request-sleep.sh"
SAFE_SLEEP_SCRIPT="/opt/pve-sleep/bin/safe-sleep.sh"

mkdir -p "$STATE_DIR" /run/pve-sleep

log() {
  echo "[battery-monitor] $*"
  command -v logger >/dev/null 2>&1 && logger -t pve-battery-monitor -- "$*" || true
}

on_ac_power() {
  local ps
  for ps in /sys/class/power_supply/*; do
    [[ -r "$ps/type" ]] || continue
    if grep -Eq 'Mains|USB|USB_C' "$ps/type" 2>/dev/null; then
      [[ -r "$ps/online" && "$(cat "$ps/online" 2>/dev/null)" == "1" ]] && return 0
    fi
  done
  return 1
}

battery_capacity() {
  local total=0 count=0 bat cap
  for bat in /sys/class/power_supply/BAT*; do
    [[ -r "$bat/capacity" ]] || continue
    cap="$(cat "$bat/capacity" 2>/dev/null || echo 0)"
    total=$((total + cap))
    count=$((count + 1))
  done

  if ((count == 0)); then
    echo 0
  else
    echo $((total / count))
  fi
}

battery_is_charging() {
  local bat
  for bat in /sys/class/power_supply/BAT*; do
    [[ -r "$bat/status" ]] || continue
    if grep -Eq 'Charging|Full' "$bat/status" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

request_sleep_pathway() {
  touch "$REQUEST_FLAG"
  log "Low battery detected. Preparing guests and requesting future sleep hook."
  if [[ -x "$SAFE_SLEEP_SCRIPT" ]]; then
    "$SAFE_SLEEP_SCRIPT" prepare || true
  fi
  if [[ -x "$HOOK_SCRIPT" ]]; then
    "$HOOK_SCRIPT" || true
  else
    log "No sleep hook is configured. Host sleep itself is intentionally not invoked."
  fi
}

while true; do
  if ls /sys/class/power_supply/BAT* >/dev/null 2>&1; then
    if ! on_ac_power && ! battery_is_charging; then
      cap="$(battery_capacity)"
      if ((cap <= LOW_BATTERY_PERCENT)); then
        request_sleep_pathway
      fi
    fi
  fi
  sleep "$CHECK_INTERVAL"
done
