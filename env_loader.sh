#!/usr/bin/env bash
# Shared .env loader for the turista-postgresql shell scripts.
#
# Mirrors the precedence rule used by
# turista-erpnext-migrator/env_loader.py: variables already exported in the
# shell take precedence over values in the .env file. Set ENV_FILE to use a
# different file.

load_env_file() {
  local env_file="${ENV_FILE:-${SCRIPT_DIR:-.}/.env}"
  [[ -f "$env_file" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#export }"
    key="${line%%=*}"
    value="${line#*=}"
    key="${key%%[[:space:]]*}"
    if [[ -z "$key" ]]; then
      continue
    fi
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
      value="${value:1:-1}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
      value="${value:1:-1}"
    fi
    if [[ -z "${!key:-}" ]]; then
      export "$key=$value"
    fi
  done < "$env_file"
}
