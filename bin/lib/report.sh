#!/usr/bin/env bash
# =============================================================================
# pve-sleep: report.sh — TXT and JSON report generation
# =============================================================================
set -u

declare -a REPORT_LINES=()

# ---------------------------------------------------------------------------
# Human-readable TXT report
# ---------------------------------------------------------------------------

render_txt_report() {
  REPORT_LINES=()

  REPORT_LINES+=("pve-sleep capability report v${PVE_SLEEP_VERSION}")
  REPORT_LINES+=("Generated: $(date -Is 2>/dev/null || date)")
  REPORT_LINES+=("Host: $HOSTNAME_VAL | Kernel: $KERNEL_VAL | Arch: $ARCH_VAL")
  REPORT_LINES+=("OS: $DISTRO_VAL | Debian: $DEBIAN_VER ($DEBIAN_CODENAME) | Proxmox: $PVE_VERSION_RAW")
  REPORT_LINES+=("")

  # --- CPU / GPU ---
  REPORT_LINES+=("CPU and GPU")
  REPORT_LINES+=("$(mark "$CPU_GOVERNOR_PRESENT") CPU governors: ${CPU_GOVERNORS:-none}")
  REPORT_LINES+=("$(mark "$CPU_POWERSAVE") CPU powersave available")
  REPORT_LINES+=("$(mark "$CPU_PERFORMANCE") CPU performance available")
  REPORT_LINES+=("  Current governor: $CPU_CURRENT_GOVERNOR")
  REPORT_LINES+=("$(mark "$GPU_CONTROL_PRESENT") GPU power controls: $GPU_CONTROL_SUMMARY")
  REPORT_LINES+=("")

  # --- Hardware ---
  REPORT_LINES+=("Hardware")
  REPORT_LINES+=("$(mark "$HAS_LID") Lid switch")
  REPORT_LINES+=("$(mark "$HAS_DISPLAY") Display: $DISPLAY_SUMMARY")
  REPORT_LINES+=("$(mark "$HAS_BUILTIN_DISPLAY") Built-in display")
  REPORT_LINES+=("$(mark "$HAS_BATTERY") Battery: $BATTERY_SUMMARY")
  REPORT_LINES+=("")

  # --- Network ---
  REPORT_LINES+=("Network adapters")
  REPORT_LINES+=("$(mark "$WOL_SUPPORTED_TOTAL") Wake-on-LAN: $WOL_SUPPORTED_TOTAL adapter(s)")
  REPORT_LINES+=("$(mark "$WOWLAN_SUPPORTED_TOTAL") Wake-on-Wireless-LAN: $WOWLAN_SUPPORTED_TOTAL adapter(s)")
  if [[ -v NETWORK_LINES && ${#NETWORK_LINES[@]} -gt 0 ]]; then
    local nl
    for nl in "${NETWORK_LINES[@]}"; do
      REPORT_LINES+=("  $nl")
    done
  else
    REPORT_LINES+=("  $CROSS No physical network adapters detected")
  fi
  REPORT_LINES+=("")

  # --- USB ---
  REPORT_LINES+=("USB devices")
  REPORT_LINES+=("$(mark "$USB_WAKE_CAPABLE_TOTAL") USB wake-capable: $USB_WAKE_CAPABLE_TOTAL (enabled: $USB_WAKE_ENABLED_TOTAL)")
  if [[ -v USB_LINES && ${#USB_LINES[@]} -gt 0 ]]; then
    local ul
    for ul in "${USB_LINES[@]}"; do
      REPORT_LINES+=("  $ul")
    done
  else
    REPORT_LINES+=("  $CROSS No USB devices enumerated")
  fi
  REPORT_LINES+=("")

  # --- Sleep ---
  REPORT_LINES+=("Sleep and wake")
  REPORT_LINES+=("$( [[ "$SUPPORTED_SLEEP_STATES" != "unknown" ]] && echo "$CHECK" || echo "$CROSS" ) Sleep states: $SUPPORTED_SLEEP_STATES")
  REPORT_LINES+=("$( [[ "$SUPPORTED_MEM_SLEEP" != "unknown" ]] && echo "$CHECK" || echo "$CROSS" ) Mem sleep: $SUPPORTED_MEM_SLEEP")
  REPORT_LINES+=("$(mark "$RTC_WAKE_SUPPORTED") RTC wake alarm")
  REPORT_LINES+=("$( [[ "$SUPPORTED_WAKE_SUMMARY" != "none detected" ]] && echo "$CHECK" || echo "$CROSS" ) Wake modes: $SUPPORTED_WAKE_SUMMARY")
  REPORT_LINES+=("")

  # --- Configuration ---
  REPORT_LINES+=("Configuration")
  REPORT_LINES+=("  logind HandleLidSwitch=$LOGIND_LID")
  REPORT_LINES+=("  logind IdleAction=$LOGIND_IDLE_ACTION IdleActionSec=$LOGIND_IDLE_SECS")
  REPORT_LINES+=("  sleep.conf: $SLEEP_CONF_LIMITS")
  REPORT_LINES+=("  GRUB consoleblank: $GRUB_CONSOLEBLANK")
  REPORT_LINES+=("  Active consoleblank: $CONSOLE_BLANK_CURRENT")
  REPORT_LINES+=("  Sleep/wake timers: $RELEVANT_TIMER_SUMMARY")
  REPORT_LINES+=("  Inhibitors: $INHIBITOR_SUMMARY")
  if [[ -v SERVICE_LINES && ${#SERVICE_LINES[@]} -gt 0 ]]; then
    local sl
    for sl in "${SERVICE_LINES[@]}"; do
      REPORT_LINES+=("  $sl")
    done
  fi
  if [[ -v TIMER_LINES && ${#TIMER_LINES[@]} -gt 0 ]]; then
    local tl
    for tl in "${TIMER_LINES[@]}"; do
      REPORT_LINES+=("  $tl")
    done
  fi
  REPORT_LINES+=("")

  # --- Packages ---
  REPORT_LINES+=("Needed packages")
  if [[ -v NEEDED_PACKAGES && ${#NEEDED_PACKAGES[@]} -gt 0 ]]; then
    local pkg
    for pkg in "${NEEDED_PACKAGES[@]}"; do
      REPORT_LINES+=("  - $pkg")
    done
  else
    REPORT_LINES+=("  $CHECK No additional packages needed")
  fi
  REPORT_LINES+=("")

  REPORT_LINES+=("Packages not found")
  if [[ -v MISSING_PACKAGES && ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
    local pkg
    for pkg in "${MISSING_PACKAGES[@]}"; do
      REPORT_LINES+=("  - $pkg")
    done
  else
    REPORT_LINES+=("  $CHECK All checked packages are resolvable via apt")
  fi
  REPORT_LINES+=("")

  # --- Limitations ---
  REPORT_LINES+=("Limitations")
  if [[ -v LIMITATIONS && ${#LIMITATIONS[@]} -gt 0 ]]; then
    local lim
    for lim in "${LIMITATIONS[@]}"; do
      REPORT_LINES+=("  $WARN_ICON $lim")
    done
  else
    REPORT_LINES+=("  $CHECK No obvious blockers detected")
  fi
}

# ---------------------------------------------------------------------------
# JSON report
# ---------------------------------------------------------------------------

write_json_report() {
  local outfile="$1"
  cat > "$outfile" <<EOF
{
  "meta": {
    "tool": "pve-sleep",
    "version": "$(json_escape "$PVE_SLEEP_VERSION")",
    "generated_at": "$(json_escape "$(date -Is 2>/dev/null || date)")"
  },
  "system": {
    "hostname": "$(json_escape "$HOSTNAME_VAL")",
    "kernel": "$(json_escape "$KERNEL_VAL")",
    "arch": "$(json_escape "$ARCH_VAL")",
    "os": "$(json_escape "$DISTRO_VAL")",
    "debian_version": "$(json_escape "$DEBIAN_VER")",
    "debian_codename": "$(json_escape "$DEBIAN_CODENAME")",
    "proxmox_version": "$(json_escape "$PVE_VERSION_RAW")",
    "proxmox_major": "$(json_escape "$PVE_MAJOR")"
  },
  "cpu_gpu": {
    "cpu_vendor": "$(json_escape "$CPU_VENDOR")",
    "cpu_governors": "$(json_escape "$CPU_GOVERNORS")",
    "cpu_governor_present": "$(json_escape "$CPU_GOVERNOR_PRESENT")",
    "cpu_powersave": "$(json_escape "$CPU_POWERSAVE")",
    "cpu_performance": "$(json_escape "$CPU_PERFORMANCE")",
    "cpu_current_governor": "$(json_escape "$CPU_CURRENT_GOVERNOR")",
    "gpu_control_present": "$(json_escape "$GPU_CONTROL_PRESENT")",
    "gpu_control_summary": "$(json_escape "$GPU_CONTROL_SUMMARY")"
  },
  "hardware": {
    "lid_switch": "$(json_escape "$HAS_LID")",
    "display_detected": "$(json_escape "$HAS_DISPLAY")",
    "built_in_display": "$(json_escape "$HAS_BUILTIN_DISPLAY")",
    "display_summary": "$(json_escape "$DISPLAY_SUMMARY")",
    "battery_detected": "$(json_escape "$HAS_BATTERY")",
    "battery_summary": "$(json_escape "$BATTERY_SUMMARY")"
  },
  "sleep": {
    "supported_sleep_states": "$(json_escape "$SUPPORTED_SLEEP_STATES")",
    "supported_mem_sleep": "$(json_escape "$SUPPORTED_MEM_SLEEP")"
  },
  "wake": {
    "wol_supported_total": $WOL_SUPPORTED_TOTAL,
    "wowlan_supported_total": $WOWLAN_SUPPORTED_TOTAL,
    "usb_wake_capable_total": $USB_WAKE_CAPABLE_TOTAL,
    "usb_wake_enabled_total": $USB_WAKE_ENABLED_TOTAL,
    "rtc_wake_supported": "$(json_escape "$RTC_WAKE_SUPPORTED")",
    "supported_wake_modes": "$(json_escape "$SUPPORTED_WAKE_SUMMARY")"
  },
  "network_adapters": $(json_raw_array NETWORK_JSON),
  "usb_devices": $(json_raw_array USB_JSON),
  "config": {
    "logind_lid_switch": "$(json_escape "$LOGIND_LID")",
    "logind_idle_action": "$(json_escape "$LOGIND_IDLE_ACTION")",
    "logind_idle_action_sec": "$(json_escape "$LOGIND_IDLE_SECS")",
    "sleep_conf_limits": "$(json_escape "$SLEEP_CONF_LIMITS")",
    "grub_consoleblank": "$(json_escape "$GRUB_CONSOLEBLANK")",
    "console_blank_current": "$(json_escape "$CONSOLE_BLANK_CURRENT")",
    "relevant_timers": "$(json_escape "$RELEVANT_TIMER_SUMMARY")",
    "inhibitors": "$(json_escape "$INHIBITOR_SUMMARY")"
  },
  "needed_packages": $(json_str_array NEEDED_PACKAGES),
  "missing_packages": $(json_str_array MISSING_PACKAGES),
  "limitations": $(json_str_array LIMITATIONS)
}
EOF
}

# ---------------------------------------------------------------------------
# Write reports to disk and print to stdout
# ---------------------------------------------------------------------------

write_reports() {
  local output_dir="$1"
  local txt_file="$output_dir/sleep-system.txt"
  local json_file="$output_dir/sleep-system.json"

  mkdir -p "$output_dir"

  # Print and save TXT
  printf '%s\n' "${REPORT_LINES[@]}" | tee "$txt_file"

  # Save JSON
  write_json_report "$json_file"

  log "Saved: $txt_file"
  log "Saved: $json_file"
}

# Save a named snapshot of the report (e.g. before/after)
copy_report_snapshot() {
  local output_dir="$1" suffix="$2"
  local txt_file="$output_dir/sleep-system.txt"
  local json_file="$output_dir/sleep-system.json"

  [[ -f "$txt_file" ]] && cp -f "$txt_file" "$output_dir/sleep-system-$suffix.txt"
  [[ -f "$json_file" ]] && cp -f "$json_file" "$output_dir/sleep-system-$suffix.json"
}
