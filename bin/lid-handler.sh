#!/usr/bin/env bash
set -u

STATE_DIR="/run/pve-sleep"
mkdir -p "$STATE_DIR"

get_lid_state() {
  local state_file
  for state_file in /proc/acpi/button/lid/*/state; do
    [[ -r "$state_file" ]] || continue
    awk '{print tolower($2)}' "$state_file"
    return 0
  done
  echo open
}

apply_console_blank() {
  if command -v setterm >/dev/null 2>&1; then
    for tty in /dev/tty0 /dev/tty1 /dev/tty2 /dev/tty3 /dev/tty4 /dev/tty5 /dev/tty6; do
      [[ -w "$tty" ]] || continue
      setterm --blank force > "$tty" || true
    done
  fi
}

restore_console_blank() {
  if [[ -x /opt/pve-sleep/bin/console-blank.sh ]]; then
    /opt/pve-sleep/bin/console-blank.sh || true
  fi
}

save_and_blank_backlights() {
  local dev cur
  for dev in /sys/class/backlight/*; do
    [[ -d "$dev" && -w "$dev/brightness" ]] || continue
    cur="$(cat "$dev/brightness" 2>/dev/null || echo 0)"
    echo "$cur" > "$STATE_DIR/$(basename "$dev").brightness"
    echo 0 > "$dev/brightness" 2>/dev/null || true
    [[ -w "$dev/bl_power" ]] && echo 4 > "$dev/bl_power" 2>/dev/null || true
  done
}

restore_backlights() {
  local dev saved
  for dev in /sys/class/backlight/*; do
    [[ -d "$dev" ]] || continue
    [[ -w "$dev/bl_power" ]] && echo 0 > "$dev/bl_power" 2>/dev/null || true
    saved="$STATE_DIR/$(basename "$dev").brightness"
    if [[ -f "$saved" && -w "$dev/brightness" ]]; then
      cat "$saved" > "$dev/brightness" 2>/dev/null || true
    fi
  done
}

case "$(get_lid_state)" in
  closed)
    save_and_blank_backlights
    apply_console_blank
    ;;
  *)
    restore_backlights
    restore_console_blank
    ;;
esac
