#!/usr/bin/env bash
set -euo pipefail

BLANK_MINUTES="${PVE_SLEEP_CONSOLE_BLANK_MINUTES:-5}"
POWERDOWN_MINUTES="${PVE_SLEEP_CONSOLE_POWERDOWN_MINUTES:-10}"

for tty in /dev/tty0 /dev/tty1 /dev/tty2 /dev/tty3 /dev/tty4 /dev/tty5 /dev/tty6; do
  [[ -w "$tty" ]] || continue
  if command -v setterm >/dev/null 2>&1; then
    setterm --blank "$BLANK_MINUTES" --powerdown "$POWERDOWN_MINUTES" --powersave on > "$tty" || true
  fi
done
