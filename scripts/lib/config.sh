#!/bin/bash
# Writes server.cfg from CVAR_ variables and checks the environment for mistakes.

is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

read_secret() {
  # $1 = variable holding the value, $2 = variable naming a file that holds it (preferred)
  local value_var="$1" file_var="$2"
  local file_path="${!file_var:-}"
  if [ -n "${file_path}" ]; then
    if [ -f "${file_path}" ]; then
      printf '%s' "$(<"${file_path}")"
      return
    fi
    echo "Warning: ${file_var} is set but the file does not exist: ${file_path}" >&2
  fi
  printf '%s' "${!value_var:-}"
}

# The cvar list depends on the gamemode and the addons, so it's only used to check names on a start
# with the gamemode and collection it was made with.
cvar_context() {
  printf 'gamemode=%s workshop=%s' "${GAMEMODE:-sandbox}" "${WORKSHOP_COLLECTION:-}"
}

cvar_rows() {
  # Reads `cvarlist` output ("name : value : flags : help"); prints "<name>\t<help>" for each
  # console variable. Commands are left out, and the value column is only the number a cvar parses to.
  awk -F ' : ' '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    NF >= 4 {
      name = trim($1)
      if (name !~ /^[A-Za-z0-9_.]+$/ || trim($2) == "cmd") next
      help = $4
      for (i = 5; i <= NF; i++) help = help " : " $i
      print name "\t" trim(help)
    }
  '
}

known_cvars() {
  # Prints the lowercase cvar names from the server's list, when it was made in the current context.
  local list="${STEAMAPPDIR}/.cvarlist"
  [ -f "${list}" ] && [ "$(head -n 1 "${list}")" = "# $(cvar_context)" ] || return 1
  tail -n +2 "${list}" | cvar_rows | cut -f1 | tr '[:upper:]' '[:lower:]'
}

cfg_values() {
  # $1 = cfg file; prints "<lowercase name>\t<value>" for each line that sets something.
  [ -f "$1" ] || return 0
  awk '
    { line = $0; sub(/\r$/, "", line); sub(/^[ \t]+/, "", line) }
    line == "" || line ~ /^\/\// { next }
    {
      name = line
      sub(/[ \t].*$/, "", name)
      value = substr(line, length(name) + 1)
      sub(/^[ \t]+/, "", value)
      if (value ~ /^"/) {
        value = substr(value, 2)
        q = index(value, "\"")
        if (q) value = substr(value, 1, q - 1)
      } else {
        sub(/[ \t]*\/\/.*$/, "", value)
        sub(/[ \t]+$/, "", value)
      }
      gsub(/"/, "", name)
      print tolower(name) "\t" value
    }
  ' "$1"
}

set_cfg_value() {
  # $1 = cfg file, $2 = cvar, $3 = value. Replaces the first line setting the cvar (case-insensitive)
  # and drops later ones, which would override it, or appends a line.
  NAME="$2" VALUE="$3" awk '
    BEGIN { name = tolower(ENVIRON["NAME"]); setting = ENVIRON["NAME"] " \"" ENVIRON["VALUE"] "\"" }
    {
      sub(/\r$/, "")
      first = $0
      sub(/^[ \t]+/, "", first)
      sub(/[ \t].*$/, "", first)
      gsub(/"/, "", first)
    }
    tolower(first) == name {
      if (!found) print setting
      found = 1
      next
    }
    { print }
    END { if (!found) print setting }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# Applies every CVAR_<name> variable to server.cfg as `<name> "<value>"`; the server runs the file on
# every map start. CVAR_<name>_FILE reads the value from a file (for Docker secrets) and wins. Once the
# server has saved its cvar list in this context, a name that isn't in it is reported, not written.
apply_cvar_env() {
  local cfg_file="$1" names name cvar value known="" check=true unknown="" invalid=""
  names="$(compgen -e | grep '^CVAR_' | sort || true)"
  [ -n "${names}" ] || return 0
  if ! known="$(known_cvars)"; then
    check=false
    echo "Config: CVAR_ names are checked from the next start, once the server has listed its console variables for gamemode ${GAMEMODE:-sandbox}${WORKSHOP_COLLECTION:+ and collection ${WORKSHOP_COLLECTION}}"
  fi
  while IFS= read -r name; do
    cvar="${name#CVAR_}"
    cvar="${cvar%_FILE}"
    if [[ "${name}" == *_FILE ]]; then
      [ -f "${!name}" ] || { echo "Warning: ${name} is set but the file does not exist: ${!name}" >&2; continue; }
      value="$(<"${!name}")"
    elif [ -n "$(printenv "${name}_FILE")" ]; then
      continue
    else
      value="${!name}"
    fi
    if [ "${check}" = true ] && ! grep -qxF "${cvar,,}" <<< "${known}"; then
      unknown="${unknown} ${name}"
      continue
    fi
    # A cfg line has no way to escape a quote, and a line break would end the setting.
    if [[ "${value}" == *[$'"\n\r']* ]]; then
      invalid="${invalid} ${name}"
      continue
    fi
    set_cfg_value "${cfg_file}" "${cvar}" "${value}"
    echo "Config: ${cvar} set from ${name}"
  done <<< "${names}"
  report_problems "these variables match no console variable of this server, so they were not applied:${unknown}
         Run 'docker exec <container> list-env' to see the valid names." "${unknown}"
  report_problems "these variables hold a double quote or a line break, which server.cfg can't hold, so they were not applied:${invalid}" "${invalid}"
}

# Warns about variables that set the same thing.
report_overlaps() {
  local names name lower
  names="$(compgen -e | grep '^CVAR_' || true)"
  overlap() {
    # $1 = image variable, $2 = case-insensitive pattern for the CVAR_ variables that duplicate it
    local others
    [ -n "${!1+x}" ] || return 0
    others="$(grep -ixE "$2" <<< "${names}" | paste -sd ' ' || true)"
    [ -z "${others}" ] || echo "Warning: $1 and ${others} set the same thing; remove ${others}." >&2
  }
  overlap GAMEMODE 'CVAR_gamemode(_FILE)?'
  overlap MAXPLAYERS 'CVAR_maxplayers(_FILE)?'
  overlap PORT 'CVAR_hostport(_FILE)?'
  overlap IP 'CVAR_ip(_FILE)?'
  overlap WORKSHOP_COLLECTION 'CVAR_host_workshop_collection(_FILE)?'
  overlap STEAM_GSLT 'CVAR_sv_setsteamaccount(_FILE)?'
  for name in STEAM_GSLT STEAM_API_KEY; do
    if [ -n "$(printenv "${name}_FILE")" ] && [ -n "${!name:-}" ]; then
      echo "Warning: ${name} and ${name}_FILE are both set; ${name}_FILE is used." >&2
    fi
  done
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    if [[ "${name}" == *_FILE ]] && grep -qxF "${name%_FILE}" <<< "${names}"; then
      echo "Warning: ${name%_FILE} and ${name} are both set; ${name} is used." >&2
    fi
  done <<< "${names}"
  # Console variables ignore case, so these set the same one and the last in server.cfg wins.
  while IFS= read -r lower; do
    [ -n "${lower}" ] || continue
    echo "Warning: $(grep -ixF "${lower}" <<< "${names}" | paste -sd ' ') differ only in case; only one is used." >&2
  done < <(tr '[:upper:]' '[:lower:]' <<< "${names}" | sort | uniq -d)
}

report_problems() {
  # $1 = message, $2 = what it is about (empty: nothing to report)
  [ -n "${2// /}" ] || return 0
  echo "Warning: $1" >&2
  if is_true "${CONFIG_STRICT:-}"; then
    echo "Error: CONFIG_STRICT is set, refusing to start." >&2
    exit 1
  fi
}

# Warns about variables this image doesn't read, such as a misspelled or renamed one. All-lowercase
# names are left alone, since those are conventions of other tools (http_proxy and the like).
report_unrecognized() {
  # $1 = file listing the variables the image sets itself
  local image_env="$1" known unrecognized
  [ -f "${image_env}" ] || return 0
  known="$(cut -f1 "${SCRIPT_DIR}/vars.tsv"; cat "${image_env}"; printf '%s\n' HOSTNAME HOME OLDPWD PATH PWD SHLVL TERM TZ HTTP_PROXY HTTPS_PROXY NO_PROXY)"
  unrecognized="$(compgen -e | grep -vE '^CVAR_|^[a-z_][a-z0-9_]*$|_SERVICE_(HOST|PORT)|_PORT_[0-9]+_|^KUBERNETES_' \
    | grep -vxF -f <(printf '%s\n' "${known}") | paste -sd ' ' || true)"
  [ -z "${unrecognized}" ] || echo "Warning: this image does not read ${unrecognized}. Run 'docker exec <container> list-env' to see the valid names." >&2
}
