#!/bin/bash
# Lists every environment variable the image reads: its own variables, then one CVAR_ variable per
# console variable of the server, from the list it made on its last start, with the value server.cfg
# sets.
# Usage: list-env [--tsv] [filter]

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=scripts/lib/config.sh
. "${SCRIPT_DIR}/lib/config.sh"

tsv=false
if [ "${1:-}" = "--tsv" ]; then
  tsv=true
  shift
fi
filter="${1:-}"

image_vars() {
  local name description value
  while IFS=$'\t' read -r name description; do
    value="${!name:-}"
    case "${name}" in
      STEAM_GSLT|STEAM_API_KEY) [ -n "${value}" ] && value="(set)" ;;
    esac
    printf 'image\t%s\t%s\t%s\n' "${name}" "${value}" "${description}"
  done < "${SCRIPT_DIR}/vars.tsv"
}

cvar_vars() {
  local list="${STEAMAPPDIR}/.cvarlist"
  [ -f "${list}" ] || return 0
  tail -n +2 "${list}" | cvar_rows | VALUES="$(cfg_values "${STEAMAPPDIR}/garrysmod/cfg/server.cfg")" awk -F '\t' '
    BEGIN {
      n = split(ENVIRON["VALUES"], lines, "\n")
      for (i = 1; i <= n; i++) {
        t = index(lines[i], "\t")
        if (t) value[substr(lines[i], 1, t - 1)] = substr(lines[i], t + 1)
      }
    }
    {
      v = value[tolower($1)]
      if (tolower($1) ~ /password|token/ && v != "") v = "(set)"
      printf "cvar\tCVAR_%s\t%s\t%s\n", $1, v, $2
    }
  '
}

rows() {
  image_vars
  cvar_vars
}

if [ ! -f "${STEAMAPPDIR}/.cvarlist" ] && [ "${tsv}" = false ]; then
  echo "# The server lists its console variables once it is up; until then only the image settings are shown." >&2
fi

rows | awk -F '\t' -v filter="${filter}" -v tsv="${tsv}" '
  filter != "" && index(tolower($2 " " $4), tolower(filter)) == 0 { next }
  tsv == "true" { print; next }
  {
    if ($1 != kind) {
      kind = $1
      printf "%s## %s\n", (shown ? "\n" : ""), (kind == "image" ? "Image settings" : "Console variables (garrysmod/cfg/server.cfg)")
    }
    shown = 1
    if ($4 != "") print "# " $4
    print $2 "=" $3
  }
'
