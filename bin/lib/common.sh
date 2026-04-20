#!/usr/bin/env bash
# =============================================================================
# pve-sleep: common.sh — shared utilities for the pve-sleep toolkit
# =============================================================================
set -u

PVE_SLEEP_VERSION="0.3.0"

# Unicode status markers
CHECK="✅"
CROSS="❌"
WARN_ICON="⚠️"

# Terminal colors
if [[ -t 1 ]]; then
  _CG=$'\e[32m'; _CY=$'\e[33m'; _CR=$'\e[31m'; _CC=$'\e[36m'; _C0=$'\e[0m'
else
  _CG=""; _CY=""; _CR=""; _CC=""; _C0=""
fi

log()  { echo "${_CG}[pve-sleep]${_C0} $*"; }
warn() { echo "${_CY}[pve-sleep]${_C0} $*" >&2; }
err()  { echo "${_CR}[pve-sleep]${_C0} $*" >&2; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }
to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Print ✅ or ❌ based on argument value
mark() {
  case "$1" in
    yes|true) printf '%s' "$CHECK" ;;
    no|false|unknown|none|"") printf '%s' "$CROSS" ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 )); then
        printf '%s' "$CHECK"
      else
        printf '%s' "$CROSS"
      fi
      ;;
  esac
}

# JSON string escaping
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Print a bash array as a JSON string array: ["a","b"]
json_str_array() {
  local arr_name="$1"
  local -a vals=()
  eval "vals=(\"\${${arr_name}[@]:-}\")"
  local first=1 item
  printf '['
  for item in "${vals[@]}"; do
    [[ -n "$item" ]] || continue
    (( first )) || printf ','
    printf '"%s"' "$(json_escape "$item")"
    first=0
  done
  printf ']'
}

# Print a bash array as a JSON raw array: [{...},{...}]
json_raw_array() {
  local arr_name="$1"
  local -a vals=()
  eval "vals=(\"\${${arr_name}[@]:-}\")"
  local first=1 item
  printf '['
  for item in "${vals[@]}"; do
    [[ -n "$item" ]] || continue
    (( first )) || printf ','
    printf '%s' "$item"
    first=0
  done
  printf ']'
}

# Check if a value is already in an array
array_contains() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# Append a value to a named array if not already present
append_unique() {
  local arr_name="$1" value="$2"
  local -a existing=()
  eval "existing=(\"\${${arr_name}[@]:-}\")"
  local item
  for item in "${existing[@]}"; do
    [[ "$item" == "$value" ]] && return 0
  done
  eval "${arr_name}+=(\"\$value\")"
}

# Interactive yes/no prompt with default
prompt_yn() {
  local prompt="$1" default="${2:-y}"
  if [[ ! -t 0 ]]; then
    [[ "$default" =~ ^[Yy] ]] && return 0 || return 1
  fi
  local answer
  if [[ "$default" =~ ^[Yy] ]]; then
    read -r -p "$prompt [Y/n]: " answer
    answer="${answer:-Y}"
  else
    read -r -p "$prompt [y/N]: " answer
    answer="${answer:-N}"
  fi
  [[ "$answer" =~ ^[Yy] ]]
}
