#!/usr/bin/env bash
set -u

apt_have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

append_unique_global() {
  local array_name="$1"
  local value="$2"
  local existing=()
  local item

  eval "existing=(\"\${${array_name}[@]}\")"
  for item in "${existing[@]}"; do
    [[ "$item" == "$value" ]] && return 0
  done
  eval "${array_name}+=(\"\$value\")"
}

pkg_candidate() {
  local pkg="$1"
  if apt_have_cmd apt-cache; then
    apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}'
  fi
}

pkg_installed_version() {
  local pkg="$1"
  dpkg-query -W -f='${Status} ${Version}\n' "$pkg" 2>/dev/null | awk '/install ok installed/ {print $4; exit}'
}

pkg_is_installed() {
  local pkg="$1"
  dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null | grep -q 'install ok installed'
}

recommend_package() {
  local pkg="$1"
  local reason="$2"
  local candidate installed line

  candidate="$(pkg_candidate "$pkg")"
  installed="$(pkg_installed_version "$pkg")"

  if [[ -n "$candidate" && "$candidate" != "(none)" ]]; then
    if [[ -z "$installed" ]]; then
      line="$pkg (candidate: $candidate) - $reason"
      append_unique_global NEEDED_PACKAGES "$line"
      append_unique_global NEEDED_PACKAGE_NAMES "$pkg"
    fi
  else
    line="$pkg - $reason"
    append_unique_global MISSING_PACKAGES "$line"
  fi
}

prompt_yes_default() {
  local prompt="$1"
  local answer default_choice="Y"
  default_choice="${2:-Y}"

  if [[ "${PVE_SLEEP_ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi

  if [[ -t 0 ]]; then
    read -r -p "$prompt [$default_choice/n]: " answer
    answer="${answer:-$default_choice}"
  else
    answer="$default_choice"
  fi

  [[ "$answer" =~ ^[Yy]$ ]]
}

apt_safety_check() {
  local pkgs=("$@")
  local sim removed

  [[ ${#pkgs[@]} -gt 0 ]] || return 0
  sim=$(apt-get -s install "${pkgs[@]}" 2>&1)

  removed=$(awk '
    /^The following packages will be REMOVED:/ { in_block=1; next }
    in_block && NF { print }
    in_block && /^$/ { exit }
  ' <<< "$sim")

  if [[ -n "$removed" ]]; then
    if grep -Eq '^(proxmox-ve|pve-manager|pve-kernel-|pve-headers-|proxmox-kernel-|pve-firewall|pve-cluster)' <<< "$removed"; then
      echo -e "Installing the following packages would REMOVE core Proxmox components:\n\n${removed}\n\nOperation aborted."
      return 1
    fi
  fi

  if grep -Eq 'linux-image-|linux-headers-' <<< "$sim"; then
    echo -e "Installing ${pkgs[*]} would install Debian kernel packages.\nThis would break Proxmox.\n\nOperation aborted."
    return 1
  fi

  if grep -Eq 'initramfs-tools' <<< "$sim"; then
    echo -e "Installing ${pkgs[*]} would install initramfs-tools.\nProxmox uses dracut.\n\nOperation aborted."
    return 1
  fi

  if grep -Eq '^Remv pve-firmware|^[[:space:]]+pve-firmware$' <<< "$sim"; then
    echo -e "Installing ${pkgs[*]} would modify or replace pve-firmware.\n\nOperation aborted."
    return 1
  fi

  if grep -Eqi 'Remv .*dracut|dracut.*REMOV' <<< "$sim"; then
    echo -e "Installing ${pkgs[*]} would remove dracut.\nThis would break Proxmox boot.\n\nOperation aborted."
    return 1
  fi

  return 0
}

safe_install() {
  local pkgs=("$@")
  [[ ${#pkgs[@]} -gt 0 ]] || return 0

  if ! apt_safety_check "${pkgs[@]}"; then
    return 1
  fi

  if DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"; then
    echo "Successfully installed: ${pkgs[*]}"
    return 0
  else
    echo "Failed to install: ${pkgs[*]}"
    return 1
  fi
}

get_missing_packages() {
  local want=("$@")
  local p
  for p in "${want[@]}"; do
    [[ -n "$p" ]] || continue
    if ! pkg_is_installed "$p"; then
      echo "$p"
    fi
  done
}

get_safe_install_subset() {
  local want=("$@")
  local candidate_set=()
  local pkg
  SAFE_PACKAGE_SET=()
  BLOCKED_PACKAGE_SET=()

  for pkg in "${want[@]}"; do
    candidate_set=("${SAFE_PACKAGE_SET[@]}" "$pkg")
    if apt_safety_check "${candidate_set[@]}" >/dev/null 2>&1; then
      SAFE_PACKAGE_SET=("${candidate_set[@]}")
    else
      BLOCKED_PACKAGE_SET+=("$pkg")
    fi
  done
}

install_packages_if_missing() {
  local want=("$@")
  local missing=()

  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && missing+=("$pkg")
  done < <(get_missing_packages "${want[@]}")

  [[ ${#missing[@]} -gt 0 ]] || return 0
  get_safe_install_subset "${missing[@]}"

  if [[ ${#SAFE_PACKAGE_SET[@]} -gt 0 ]]; then
    if safe_install "${SAFE_PACKAGE_SET[@]}"; then
      return 1
    fi
  fi

  return 2
}

prompt_and_install_packages() {
  local pkgs=("$@")
  local missing=() pkg candidate

  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && missing+=("$pkg")
  done < <(get_missing_packages "${pkgs[@]}")

  [[ ${#missing[@]} -gt 0 ]] || return 0
  get_safe_install_subset "${missing[@]}"

  if [[ ${#SAFE_PACKAGE_SET[@]} -gt 0 ]]; then
    echo "The following needed packages are available and safe to install in one pass:"
    for pkg in "${SAFE_PACKAGE_SET[@]}"; do
      candidate="$(pkg_candidate "$pkg")"
      echo " - $pkg${candidate:+ (candidate: $candidate)}"
    done
  fi

  if [[ ${#BLOCKED_PACKAGE_SET[@]} -gt 0 ]]; then
    echo "The following packages are still needed but were blocked by Proxmox safety checks and were not selected for installation:"
    for pkg in "${BLOCKED_PACKAGE_SET[@]}"; do
      candidate="$(pkg_candidate "$pkg")"
      echo " - $pkg${candidate:+ (candidate: $candidate)}"
    done
  fi

  [[ ${#SAFE_PACKAGE_SET[@]} -gt 0 ]] || return 12

  if prompt_yes_default "Install the safe package set now?" "Y"; then
    if safe_install "${SAFE_PACKAGE_SET[@]}"; then
      return 10
    else
      return 12
    fi
  fi

  echo "Package installation skipped by user."
  return 11
}
