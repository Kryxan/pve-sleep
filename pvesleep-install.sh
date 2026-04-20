#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# pvesleep-install.sh — installer for the pve-sleep toolkit
#
# Installs into /opt/pve-sleep (or --prefix), creates symlinks for systemd
# unit files and udev rules, then optionally runs the detector/configurator.
# =============================================================================

if [[ -t 1 ]]; then
  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_RESET=$'\e[0m'
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

log()  { echo "${C_GREEN}[install]${C_RESET} $*"; }
warn() { echo "${C_YELLOW}[install] WARNING:${C_RESET} $*" >&2; }
err()  { echo "${C_RED}[install] ERROR:${C_RESET} $*" >&2; }

PREFIX="/opt/pve-sleep"
RUN_DETECT=1
UNINSTALL=0
DETECT_ARGS=()
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_SOURCE_DIR="$ROOT_DIR/bin"

usage() {
  cat <<EOF
Usage: $0 [--prefix DIR] [--uninstall] [--no-detect] [--help]
          [--install-missing|--no-install-missing]
          [--enable-wake|--no-enable-wake]
          [--configure-wifi SSID PASSWORD|--no-configure-wifi]

Examples:
  $0
    # Install and run interactive detection/configuration
  $0 --install-missing --enable-wake --configure-wifi "SSID" "PASSWORD"
    # Install with all features enabled, no prompts
  $0 --no-install-missing --no-enable-wake --no-configure-wifi
    # Install with all features disabled
  $0 --uninstall

Notes:
  - Running with no flags is interactive.
  - Flags are passed through to pve-sleep-detect.sh.
  - Re-running the installer is safe and will refresh installed files.
EOF
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Please run this installer as root."
    exit 1
  fi
}

install_symlink() {
  local source_file="$1" target_link="$2"
  mkdir -p "$(dirname "$target_link")"
  rm -f "$target_link"
  ln -s "$source_file" "$target_link"
}

remove_path_if_present() {
  local target="$1"
  [[ -e "$target" || -L "$target" ]] && rm -f "$target"
  return 0
}

stop_and_disable_units() {
  local units=(
    console-blank.service
    pve-battery-monitor.service
    pve-network-failover.service
    pve-lid-handler.service
    pve-sleep-boot.service
    pve-safe-sleep.service
  )
  local unit
  if command -v systemctl >/dev/null 2>&1; then
    for unit in "${units[@]}"; do
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
    done
    systemctl daemon-reload || true
    systemctl reset-failed >/dev/null 2>&1 || true
  fi
}

reload_udev_rules() {
  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules || true
    udevadm trigger || true
  fi
}

install_files() {
  local bin_dir="$PREFIX/bin"
  local lib_dir="$bin_dir/lib"
  mkdir -p "$bin_dir" "$lib_dir" "$PREFIX/hooks"

  if [[ ! -d "$BIN_SOURCE_DIR" ]]; then
    err "Could not find the bin directory next to the installer."
    exit 1
  fi

  # Copy all files, preserving lib/ structure
  if [[ "$bin_dir" != "$BIN_SOURCE_DIR" ]]; then
    cp -f "$BIN_SOURCE_DIR"/*.sh "$bin_dir/" 2>/dev/null || true
    cp -f "$BIN_SOURCE_DIR"/*.service "$bin_dir/" 2>/dev/null || true
    cp -f "$BIN_SOURCE_DIR"/*.rules "$bin_dir/" 2>/dev/null || true
    cp -f "$BIN_SOURCE_DIR"/lib/*.sh "$lib_dir/" 2>/dev/null || true
    cp -f "$BIN_SOURCE_DIR/pve-sleep-detect.sh" "$PREFIX/pve-sleep-detect.sh"
    cp -f "$0" "$PREFIX/pvesleep-install.sh"
    [[ -f "$ROOT_DIR/README.md" ]] && cp -f "$ROOT_DIR/README.md" "$PREFIX/README.md"
  fi

  chmod 0755 "$bin_dir"/*.sh "$lib_dir"/*.sh "$PREFIX/pve-sleep-detect.sh" "$PREFIX/pvesleep-install.sh"
  chmod 0644 "$bin_dir"/*.service "$bin_dir"/*.rules 2>/dev/null || true

  # Symlinks for /usr/local/bin convenience
  for script in pve-sleep-detect.sh safe-sleep.sh sleep-boot.sh battery-monitor.sh network-failover-monitor.sh; do
    [[ -f "$bin_dir/$script" ]] && install_symlink "$bin_dir/$script" "/usr/local/bin/$script"
  done

  # Udev rules
  install_symlink "$bin_dir/99-lid.rules" "/etc/udev/rules.d/99-pve-sleep-lid.rules"

  # Systemd service units
  install_symlink "$bin_dir/console-blank.service" "/etc/systemd/system/console-blank.service"
  install_symlink "$bin_dir/pve-lid-handler.service" "/etc/systemd/system/pve-lid-handler.service"
  install_symlink "$bin_dir/pve-battery-monitor.service" "/etc/systemd/system/pve-battery-monitor.service"
  install_symlink "$bin_dir/pve-network-failover.service" "/etc/systemd/system/pve-network-failover.service"
  install_symlink "$bin_dir/pve-sleep-boot.service" "/etc/systemd/system/pve-sleep-boot.service"
  install_symlink "$bin_dir/pve-safe-sleep.service" "/etc/systemd/system/pve-safe-sleep.service"

  # Boot config directory
  mkdir -p /etc/pve-sleep

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    systemctl enable --now console-blank.service pve-battery-monitor.service pve-network-failover.service >/dev/null 2>&1 || true
    systemctl enable pve-sleep-boot.service pve-safe-sleep.service >/dev/null 2>&1 || true
    systemctl restart console-blank.service >/dev/null 2>&1 || true
  fi

  reload_udev_rules
}

uninstall_files() {
  log "Disabling and removing pve-sleep services and rules from $PREFIX"
  stop_and_disable_units

  remove_path_if_present "/etc/udev/rules.d/99-pve-sleep-lid.rules"
  remove_path_if_present "/etc/systemd/system/console-blank.service"
  remove_path_if_present "/etc/systemd/system/pve-lid-handler.service"
  remove_path_if_present "/etc/systemd/system/pve-battery-monitor.service"
  remove_path_if_present "/etc/systemd/system/pve-network-failover.service"
  remove_path_if_present "/etc/systemd/system/pve-sleep-boot.service"
  remove_path_if_present "/etc/systemd/system/pve-safe-sleep.service"

  # /usr/local/bin symlinks
  for script in pve-sleep-detect.sh safe-sleep.sh sleep-boot.sh battery-monitor.sh network-failover-monitor.sh; do
    remove_path_if_present "/usr/local/bin/$script"
  done

  reload_udev_rules

  local managed=(
    "$PREFIX/pve-sleep-detect.sh"
    "$PREFIX/pvesleep-install.sh"
    "$PREFIX/README.md"
    "$PREFIX/sleep-system.txt"
    "$PREFIX/sleep-system.json"
    "$PREFIX/sleep-system-before.txt"
    "$PREFIX/sleep-system-before.json"
    "$PREFIX/sleep-system-after.txt"
    "$PREFIX/sleep-system-after.json"
    "$PREFIX/bin/99-lid.rules"
    "$PREFIX/bin/aptfunctions.sh"
    "$PREFIX/bin/battery-monitor.sh"
    "$PREFIX/bin/console-blank.service"
    "$PREFIX/bin/console-blank.sh"
    "$PREFIX/bin/lid-handler.sh"
    "$PREFIX/bin/network-failover-monitor.sh"
    "$PREFIX/bin/networkwake.sh"
    "$PREFIX/bin/pve-battery-monitor.service"
    "$PREFIX/bin/pve-lid-handler.service"
    "$PREFIX/bin/pve-network-failover.service"
    "$PREFIX/bin/pve-sleep-boot.service"
    "$PREFIX/bin/pve-safe-sleep.service"
    "$PREFIX/bin/pve-sleep-detect.sh"
    "$PREFIX/bin/safe-sleep.sh"
    "$PREFIX/bin/sleep-boot.sh"
    "$PREFIX/bin/lib/common.sh"
    "$PREFIX/bin/lib/detect.sh"
    "$PREFIX/bin/lib/network.sh"
    "$PREFIX/bin/lib/packages.sh"
    "$PREFIX/bin/lib/configure.sh"
    "$PREFIX/bin/lib/report.sh"
  )

  local path
  for path in "${managed[@]}"; do
    remove_path_if_present "$path"
  done

  rmdir "$PREFIX/bin/lib" 2>/dev/null || true
  rmdir "$PREFIX/bin" 2>/dev/null || true
  rmdir "$PREFIX/hooks" 2>/dev/null || true
  rmdir "$PREFIX" 2>/dev/null || true
  warn "Custom hooks, /etc/pve-sleep, and Wi-Fi configuration were left untouched."
  log "Uninstall complete"
}

# --- Parse arguments ---
while (($#)); do
  case "$1" in
    --prefix)
      [[ -n "${2:-}" ]] || { err "Missing value for --prefix"; exit 1; }
      PREFIX="$2"; shift 2 ;;
    --uninstall)
      UNINSTALL=1; shift ;;
    --no-detect)
      RUN_DETECT=0; shift ;;
    -h|--help)
      usage; exit 0 ;;
    # All detector/configurator flags are passed through
    --install-missing|--no-install-missing|--enable-wake|--no-enable-wake|--no-configure-wifi)
      DETECT_ARGS+=("$1"); shift ;;
    --configure-wifi)
      DETECT_ARGS+=("$1")
      [[ -n "${2:-}" && -n "${3:-}" ]] || { err "--configure-wifi requires SSID PASSWORD"; exit 1; }
      DETECT_ARGS+=("$2" "$3"); shift 3 ;;
    --)
      shift; DETECT_ARGS+=("$@"); break ;;
    *)
      DETECT_ARGS+=("$1"); shift ;;
  esac
done

require_root

if ((UNINSTALL == 1)); then
  uninstall_files
  exit 0
fi

log "Installing pve-sleep into $PREFIX"
install_files
log "Installer saved to $PREFIX/pvesleep-install.sh"

if ((RUN_DETECT == 1)); then
  log "Running detection and configuration..."
  "$PREFIX/pve-sleep-detect.sh" --output-dir "$PREFIX" "${DETECT_ARGS[@]}"
  log "Detection complete: $PREFIX/sleep-system.txt and $PREFIX/sleep-system.json"
else
  log "Detection skipped (--no-detect)"
fi

log "Main detector: $PREFIX/pve-sleep-detect.sh"
log "Safe sleep: $PREFIX/bin/safe-sleep.sh {prepare|restore|sleep|status}"
log "Boot config: /etc/pve-sleep/boot.conf"