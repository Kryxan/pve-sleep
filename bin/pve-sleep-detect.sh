#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# pve-sleep-detect.sh — main orchestrator
#
# Detects hardware capabilities, recommends packages, generates reports,
# and configures wake/WiFi/governors/sleep in a single pass.
#
# Usage:
#   pve-sleep-detect.sh [OPTIONS]
#
# Options:
#   --output-dir DIR               Where to save reports (default: script dir)
#   --install-missing              Install needed packages without prompting
#   --no-install-missing           Skip package installation
#   --enable-wake                  Enable WoL/WoWLAN/USB wake without prompting
#   --no-enable-wake               Skip wake configuration
#   --configure-wifi SSID PASS     Configure WiFi failover (no prompt)
#   --no-configure-wifi            Skip WiFi configuration
#   -h, --help                     Show this help
#
# With no flags, prompts interactively for each step.
# =============================================================================

# --- Resolve library directory ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR=""
if [[ -d "$SCRIPT_DIR/lib" ]]; then
  LIB_DIR="$SCRIPT_DIR/lib"
elif [[ -d "$SCRIPT_DIR/bin/lib" ]]; then
  LIB_DIR="$SCRIPT_DIR/bin/lib"
else
  echo "[ERROR] Cannot find lib/ directory relative to $SCRIPT_DIR" >&2
  exit 1
fi

# --- Source libraries (order matters) ---
. "$LIB_DIR/common.sh"
. "$LIB_DIR/network.sh"
. "$LIB_DIR/packages.sh"
. "$LIB_DIR/detect.sh"
. "$LIB_DIR/configure.sh"
. "$LIB_DIR/report.sh"

# --- Default state ---
# 0=skip, 1=prompt, 2=auto
INSTALL_MISSING_MODE=1
ENABLE_WAKE_MODE=1
CONFIGURE_WIFI_MODE=1
WIFI_SSID=""
WIFI_PASS=""
OUTPUT_DIR="$SCRIPT_DIR"

# --- Argument parsing ---
while (( $# )); do
  case "$1" in
    --output-dir)
      [[ -n "${2:-}" ]] || { err "Missing value for --output-dir"; exit 1; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --install-missing)
      INSTALL_MISSING_MODE=2
      shift
      ;;
    --no-install-missing)
      INSTALL_MISSING_MODE=0
      shift
      ;;
    --enable-wake)
      ENABLE_WAKE_MODE=2
      shift
      ;;
    --no-enable-wake)
      ENABLE_WAKE_MODE=0
      shift
      ;;
    --configure-wifi)
      CONFIGURE_WIFI_MODE=2
      WIFI_SSID="${2:-}"
      WIFI_PASS="${3:-}"
      if [[ -z "$WIFI_SSID" || -z "$WIFI_PASS" ]]; then
        err "--configure-wifi requires SSID and PASSWORD."
        exit 1
      fi
      shift 3
      ;;
    --no-configure-wifi)
      CONFIGURE_WIFI_MODE=0
      shift
      ;;
    -h|--help)
      head -n 20 "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# =============================================================================
# PHASE 1: DETECT
# =============================================================================

log "Phase 1: System detection..."
run_all_detection

# =============================================================================
# PHASE 2: RECOMMEND PACKAGES
# =============================================================================

log "Phase 2: Package recommendations..."
recommend_packages

# =============================================================================
# PHASE 3: INITIAL REPORT
# =============================================================================

log "Phase 3: Generating report..."
render_txt_report
write_reports "$OUTPUT_DIR"
copy_report_snapshot "$OUTPUT_DIR" "before"

# =============================================================================
# PHASE 4: INSTALL PACKAGES
# =============================================================================

log "Phase 4: Package management..."
pkg_result=0
configure_packages_step "$INSTALL_MISSING_MODE" || pkg_result=$?

# If packages were installed (rc=10), re-detect and update report
if (( pkg_result == 10 )); then
  log "Re-running detection after package installation..."
  NETWORK_LINES=(); NETWORK_JSON=()
  USB_LINES=(); USB_JSON=()
  SERVICE_LINES=(); TIMER_LINES=(); LIMITATIONS=()
  run_all_detection
  recommend_packages
  render_txt_report
  write_reports "$OUTPUT_DIR"
  copy_report_snapshot "$OUTPUT_DIR" "after"
fi

# =============================================================================
# PHASE 5: CONFIGURE WAKE
# =============================================================================

log "Phase 5: Wake configuration..."
configure_wake_step "$ENABLE_WAKE_MODE"

# =============================================================================
# PHASE 6: CONFIGURE WIFI FAILOVER
# =============================================================================

log "Phase 6: WiFi failover..."
configure_wifi_step "$CONFIGURE_WIFI_MODE" "$WIFI_SSID" "$WIFI_PASS"

# =============================================================================
# PHASE 7: GOVERNORS AND POWER (always, no prompt)
# =============================================================================

log "Phase 7: CPU/GPU governors..."
configure_governors

# =============================================================================
# PHASE 8: CONSOLE BLANK (always, no prompt)
# =============================================================================

log "Phase 8: Console blanking..."
configure_console_blank

# =============================================================================
# PHASE 9: SLEEP MODE VERIFICATION
# =============================================================================

log "Phase 9: Sleep mode setup..."
configure_sleep_modes

# =============================================================================
# PHASE 10: BOOT SERVICE (persistence)
# =============================================================================

log "Phase 10: Boot persistence..."
configure_boot_service "${OUTPUT_DIR%/bin*}"

# =============================================================================
# DONE
# =============================================================================

echo ""
log "===== pve-sleep configuration complete ====="
log "Reports saved to: $OUTPUT_DIR/sleep-system.{txt,json}"
log "Run '$0 --help' to see all options."