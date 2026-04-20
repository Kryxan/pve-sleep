#!/usr/bin/env bash
# =============================================================================
# pve-sleep: packages.sh — apt package management and recommendation
# =============================================================================
set -u

# Global arrays populated by recommend_packages()
declare -a NEEDED_PACKAGES=() NEEDED_PACKAGE_NAMES=() MISSING_PACKAGES=()

# ---------------------------------------------------------------------------
# Apt helpers
# ---------------------------------------------------------------------------

pkg_candidate() {
  local pkg="$1"
  have_cmd apt-cache || return 1
  apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}'
}

pkg_installed_version() {
  local pkg="$1"
  dpkg-query -W -f='${Status} ${Version}\n' "$pkg" 2>/dev/null | awk '/install ok installed/ {print $4; exit}'
}

pkg_is_installed() {
  dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -q 'install ok installed'
}

# Record a package recommendation with apt verification
recommend_package() {
  local pkg="$1" reason="$2"
  local candidate installed line

  # Already installed — skip
  installed="$(pkg_installed_version "$pkg" 2>/dev/null || true)"
  [[ -z "$installed" ]] || return 0

  candidate="$(pkg_candidate "$pkg" 2>/dev/null || true)"
  if [[ -n "$candidate" && "$candidate" != "(none)" ]]; then
    line="$pkg (candidate: $candidate) — $reason"
    append_unique NEEDED_PACKAGES "$line"
    append_unique NEEDED_PACKAGE_NAMES "$pkg"
  else
    line="$pkg — $reason (not found in apt)"
    append_unique MISSING_PACKAGES "$line"
  fi
}

# ---------------------------------------------------------------------------
# Package recommendation engine
# ---------------------------------------------------------------------------

recommend_packages() {
  NEEDED_PACKAGES=(); NEEDED_PACKAGE_NAMES=(); MISSING_PACKAGES=()

  local cpu_lc pve_firmware_installed="no"
  cpu_lc="$(to_lower "$CPU_VENDOR")"
  pkg_is_installed pve-firmware && pve_firmware_installed="yes"

  # --- Battery / lid support ---
  if [[ "$HAS_BATTERY" == "yes" || "$HAS_LID" == "yes" ]]; then
    recommend_package acpi "battery and lid status reporting"
    recommend_package upower "battery and power policy reporting"
  fi

  # --- Network tools ---
  recommend_package ethtool "Wake-on-LAN inspection and configuration"

  # --- WiFi tools (if wifi hardware detected) ---
  local has_wifi="no"
  local line
  for line in "${NETWORK_LINES[@]:-}"; do
    [[ "$line" == *"(wifi,"* ]] && has_wifi="yes"
  done

  if [[ "$has_wifi" == "yes" ]]; then
    recommend_package iw "wireless capability inspection and WoWLAN"
    recommend_package wireless-regdb "wireless regulatory database"
    recommend_package wpasupplicant "Wi-Fi authentication (wpa_supplicant)"
  fi

  # --- CPU microcode ---
  if [[ "$cpu_lc" == *intel* ]]; then
    recommend_package intel-microcode "Intel CPU microcode updates"
  elif [[ "$cpu_lc" == *amd* ]]; then
    recommend_package amd64-microcode "AMD CPU microcode updates"
  fi

  # --- WiFi firmware (only if pve-firmware is not installed) ---
  if [[ "$pve_firmware_installed" == "no" && "$has_wifi" == "yes" ]]; then
    local wifi_vendor=""
    if have_cmd lspci; then
      local pci_net
      pci_net="$(lspci 2>/dev/null | grep -Ei 'network|wireless' || true)"
      if echo "$pci_net" | grep -qi 'intel'; then
        wifi_vendor="intel"
      elif echo "$pci_net" | grep -qi 'realtek'; then
        wifi_vendor="realtek"
      elif echo "$pci_net" | grep -qi 'broadcom'; then
        wifi_vendor="broadcom"
      elif echo "$pci_net" | grep -qi 'qualcomm\|atheros'; then
        wifi_vendor="atheros"
      elif echo "$pci_net" | grep -qi 'mediatek'; then
        wifi_vendor="mediatek"
      fi
    fi

    # Also check driver name from sysfs
    if [[ -z "$wifi_vendor" ]]; then
      local wifi_iface
      wifi_iface="$(nw_first_wifi_iface 2>/dev/null || true)"
      if [[ -n "$wifi_iface" ]]; then
        local drv
        drv="$(basename "$(readlink -f "/sys/class/net/$wifi_iface/device/driver" 2>/dev/null)" 2>/dev/null || true)"
        case "$drv" in
          iwlwifi|iwlmvm) wifi_vendor="intel" ;;
          rtw88*|r8*|rtl*) wifi_vendor="realtek" ;;
          brcmfmac|brcmsmac) wifi_vendor="broadcom" ;;
          ath9k*|ath10k*|ath11k*) wifi_vendor="atheros" ;;
          mt76*) wifi_vendor="mediatek" ;;
        esac
      fi
    fi

    case "$wifi_vendor" in
      intel)    recommend_package firmware-iwlwifi "Intel wireless firmware" ;;
      realtek)  recommend_package firmware-realtek "Realtek wireless/ethernet firmware" ;;
      broadcom) recommend_package firmware-brcm80211 "Broadcom wireless firmware" ;;
      atheros)  recommend_package firmware-atheros "Qualcomm/Atheros wireless firmware" ;;
      mediatek) recommend_package firmware-mediatek "MediaTek wireless firmware" ;;
    esac
  fi

  # Note: Do NOT recommend graphics drivers for GPU governor control
}

# ---------------------------------------------------------------------------
# Safe installation
# ---------------------------------------------------------------------------

# Simulate installation and check for dangerous removals
apt_safety_check() {
  local pkgs=("$@")
  (( ${#pkgs[@]} > 0 )) || return 0

  local sim
  sim="$(apt-get -s install "${pkgs[@]}" 2>&1)"

  local removed
  removed="$(awk '/^The following packages will be REMOVED:/{in_block=1;next} in_block && NF{print} in_block && /^$/{exit}' <<< "$sim")"

  if [[ -n "$removed" ]]; then
    if grep -Eq '^(proxmox-ve|pve-manager|pve-kernel-|pve-headers-|proxmox-kernel-|pve-firewall|pve-cluster)' <<< "$removed"; then
      echo "Would REMOVE core Proxmox packages: $removed"
      return 1
    fi
  fi

  # Block Debian kernel packages on Proxmox
  if grep -Eq 'linux-image-|linux-headers-' <<< "$sim"; then
    echo "Would install Debian kernel packages — breaks Proxmox."
    return 1
  fi

  # Block initramfs-tools (Proxmox uses dracut)
  if grep -Eq 'initramfs-tools' <<< "$sim"; then
    echo "Would install initramfs-tools — Proxmox uses dracut."
    return 1
  fi

  # Block pve-firmware removal
  if grep -Eq 'Remv pve-firmware|pve-firmware' <<< "$removed"; then
    echo "Would remove pve-firmware."
    return 1
  fi

  # Block dracut removal
  if grep -Eqi 'Remv.*dracut|dracut.*REMOV' <<< "$sim"; then
    echo "Would remove dracut — breaks Proxmox boot."
    return 1
  fi

  return 0
}

safe_install() {
  local pkgs=("$@")
  (( ${#pkgs[@]} > 0 )) || return 0

  if ! apt_safety_check "${pkgs[@]}"; then
    return 1
  fi

  if DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"; then
    log "Installed: ${pkgs[*]}"
    return 0
  else
    err "Failed to install: ${pkgs[*]}"
    return 1
  fi
}

# Get subset that is safe to install
get_safe_install_subset() {
  local want=("$@")
  SAFE_PACKAGE_SET=()
  BLOCKED_PACKAGE_SET=()
  local pkg candidate_set

  for pkg in "${want[@]}"; do
    candidate_set=("${SAFE_PACKAGE_SET[@]}" "$pkg")
    if apt_safety_check "${candidate_set[@]}" >/dev/null 2>&1; then
      SAFE_PACKAGE_SET=("${candidate_set[@]}")
    else
      BLOCKED_PACKAGE_SET+=("$pkg")
    fi
  done
}

# Get list of packages that are needed but not installed
get_missing_packages() {
  local want=("$@") p
  for p in "${want[@]}"; do
    [[ -n "$p" ]] || continue
    pkg_is_installed "$p" || echo "$p"
  done
}

# Prompt once to install all safe packages. Returns:
# 10 = installed, 11 = skipped by user, 12 = blocked/failed, 0 = none needed
prompt_and_install_packages() {
  local pkgs=("$@")
  local -a missing=()
  local pkg candidate

  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && missing+=("$pkg")
  done < <(get_missing_packages "${pkgs[@]}")

  (( ${#missing[@]} > 0 )) || return 0

  get_safe_install_subset "${missing[@]}"

  if (( ${#SAFE_PACKAGE_SET[@]} > 0 )); then
    echo ""
    echo "The following packages are needed and safe to install:"
    for pkg in "${SAFE_PACKAGE_SET[@]}"; do
      candidate="$(pkg_candidate "$pkg" 2>/dev/null || true)"
      echo "  - $pkg${candidate:+ (candidate: $candidate)}"
    done
  fi

  if (( ${#BLOCKED_PACKAGE_SET[@]} > 0 )); then
    echo ""
    echo "Blocked by Proxmox safety checks (will not install):"
    for pkg in "${BLOCKED_PACKAGE_SET[@]}"; do
      echo "  - $pkg"
    done
  fi

  (( ${#SAFE_PACKAGE_SET[@]} > 0 )) || return 12

  if prompt_yn "Install the safe package set now?"; then
    if safe_install "${SAFE_PACKAGE_SET[@]}"; then
      return 10
    else
      return 12
    fi
  fi

  echo "Package installation skipped."
  return 11
}

# Non-interactive install of all safe packages
auto_install_packages() {
  local pkgs=("$@")
  local -a missing=()
  local pkg

  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && missing+=("$pkg")
  done < <(get_missing_packages "${pkgs[@]}")

  (( ${#missing[@]} > 0 )) || return 0

  get_safe_install_subset "${missing[@]}"

  if (( ${#SAFE_PACKAGE_SET[@]} > 0 )); then
    log "Auto-installing: ${SAFE_PACKAGE_SET[*]}"
    safe_install "${SAFE_PACKAGE_SET[@]}" && return 10 || return 12
  fi

  return 0
}
