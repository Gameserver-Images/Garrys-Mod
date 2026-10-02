#!/bin/bash
# Writes settings/users.txt, which the base gamemode reads to put players in the superadmin or admin
# group, from SUPERADMINS and ADMINS.

steam_id() {
  # $1 = STEAM_X:Y:Z, [U:1:N] or a SteamID64; prints it as STEAM_0:Y:Z, the form users.txt needs.
  local id="$1" account
  if [[ "${id}" =~ ^STEAM_[0-5]:([01]):([0-9]+)$ ]]; then
    printf 'STEAM_0:%s:%s\n' "${BASH_REMATCH[1]}" "$((10#${BASH_REMATCH[2]}))"
    return 0
  elif [[ "${id}" =~ ^\[U:1:([0-9]+)\]$ ]]; then
    account="$((10#${BASH_REMATCH[1]}))"
  elif [[ "${id}" =~ ^7656119[0-9]{10}$ ]] && [ "${id}" -gt 76561197960265728 ]; then
    account="$((id - 76561197960265728))"
  else
    return 1
  fi
  printf 'STEAM_0:%s:%s\n' "$((account % 2))" "$((account / 2))"
}

apply_admins() {
  # $1 = users.txt. Rewritten whenever SUPERADMINS or ADMINS is set; neither set leaves it alone.
  local file="$1" group var entry id invalid="" count=0
  local -a entries=()
  [ -n "${SUPERADMINS+x}${ADMINS+x}" ] || return 0
  mkdir -p "$(dirname "${file}")"
  {
    printf '"Users"\n{\n'
    for group in superadmin admin; do
      var=SUPERADMINS
      [ "${group}" = admin ] && var=ADMINS
      printf '\t"%s"\n\t{\n' "${group}"
      IFS=';' read -ra entries <<< "${!var:-}"
      for entry in "${entries[@]}"; do
        entry="${entry//[[:space:]]/}"
        [ -n "${entry}" ] || continue
        if id="$(steam_id "${entry}")"; then
          printf '\t\t"%s"\t"%s"\n' "${id}" "${id}"
          count=$((count + 1))
        else
          invalid="${invalid} ${var}:${entry}"
        fi
      done
      printf '\t}\n'
    done
    printf '}\n'
  } > "${file}.tmp" && mv "${file}.tmp" "${file}"
  echo "Config: ${count} admins written to settings/users.txt"
  report_problems "these entries are not SteamIDs (STEAM_0:1:23, [U:1:47] or 7656119...), so they were left out:${invalid}" "${invalid}"
}
