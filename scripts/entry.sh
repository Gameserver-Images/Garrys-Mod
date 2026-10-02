#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_CONSOLE="/tmp/gmod-console"
SERVER_PID_FILE="/tmp/gmod-server.pid"
CVARLIST="${STEAMAPPDIR}/.cvarlist"

# As PID 1 the shell ignores signals it has no trap for, so `docker stop` would wait out the grace period.
trap 'exit 143' TERM INT

# shellcheck source=scripts/configure.sh
. "${SCRIPT_DIR}/configure.sh"

unwritable_dir() {
  # $1 = folder; prints the first folder in it the server can't write. Folders mounted into it are
  # skipped, since they may be read-only on purpose.
  local mount
  local -a prune=()
  while IFS= read -r mount; do
    prune+=(-path "${mount}" -prune -o)
  done < <(awk -v root="$1/" 'index($5, root) == 1 { print $5 }' /proc/self/mountinfo 2>/dev/null)
  find "$1" "${prune[@]}" -type d ! -writable -print -quit 2>/dev/null
}

blocked="$(unwritable_dir "${STEAMAPPDIR}")"
if [ -n "${blocked}" ]; then
  echo "Error: ${blocked} is not writable by $(id -un) (uid $(id -u)). For a bind mount, run: chown -R $(id -u):$(id -g) <host folder>" >&2
  echo "If a folder is mounted inside ${STEAMAPPDIR}, Docker created the folders leading to it as root: mount it into garrysmod/addons, garrysmod/data or garrysmod/gamemodes, which the image creates, or chown the volume." >&2
  exit 1
fi

update_game
update_mounts
cd "${STEAMAPPDIR}" || exit 1
configure_server

# The x86-64 branch also has the 64-bit server.
server=srcds_run
[ -f srcds_run_x64 ] && server=srcds_run_x64
echo "Server: starting ${server} on port ${PORT:-27015} (UDP for players, TCP for RCON)"

# Docker only signals PID 1, so stdin is a FIFO held open here: `console` writes commands into it, and
# SIGTERM/SIGINT write `quit` so the server shuts down properly.
rm -f "${SERVER_CONSOLE}"
mkfifo "${SERVER_CONSOLE}"
exec {CONSOLE_FD}<>"${SERVER_CONSOLE}"

shutdown_server() {
  [ -n "${SHUTDOWN_STARTED:-}" ] && return
  SHUTDOWN_STARTED=1
  echo "*** INFO: Shutdown signal received, sending 'quit' to the server ***"
  printf 'quit\n' >&"${CONSOLE_FD}"
  # A further signal interrupts wait with 128+n while the server is still shutting down.
  while true; do
    wait "${SERVER_PID}"
    SHUTDOWN_EXIT=$?
    if [ "${SHUTDOWN_EXIT}" -le 128 ] || ! kill -0 "${SERVER_PID}" 2>/dev/null; then
      break
    fi
  done
  echo "*** INFO: Server stopped with exit code ${SHUTDOWN_EXIT} ***"
}

# Output passes through this loop. It saves the output of `cvarlist` to CVARLIST instead of the log.
# It's a child of this shell, so the last lines are waited for before the container exits.
exec {LOG_FD}> >(
  trap '' TERM INT
  capturing=false
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%$'\r'}"
    if [ "${capturing}" = true ]; then
      if [[ "${line}" == *"total convars/concommands"* ]]; then
        capturing=false
        mv "${CVARLIST}.tmp" "${CVARLIST}"
        echo "Server: listed $(tail -n +2 "${CVARLIST}" | cvar_rows | wc -l) console variables for list-env and the CVAR_ checks"
        continue
      fi
      if [[ "${line}" == *" : "* ]]; then
        printf '%s\n' "${line}" >> "${CVARLIST}.tmp"
        continue
      fi
      [[ "${line}" =~ ^-+$ ]] && continue
    elif [[ "${line}" =~ ^[[:space:]]*cvar\ list[[:space:]]*$ ]]; then
      capturing=true
      printf '# %s\n' "$(cvar_context)" > "${CVARLIST}.tmp"
      continue
    fi
    printf '%s\n' "${line}"
  done
)
LOG_PID=$!
"./${server}" "${ARGS[@]}" <"${SERVER_CONSOLE}" >&"${LOG_FD}" 2>&1 &
SERVER_PID=$!
exec {LOG_FD}>&-
echo "${SERVER_PID}" > "${SERVER_PID_FILE}"
trap shutdown_server TERM INT

# Once the server answers queries, it lists its console variables for the next start's checks.
(
  until "${SCRIPT_DIR}/server_info.sh" > /dev/null 2>&1; do
    kill -0 "${SERVER_PID}" 2>/dev/null || exit 0
    sleep 2
  done
  echo "Server: answering queries"
  printf 'cvarlist\n' > "${SERVER_CONSOLE}"
) &
WATCH_PID=$!

wait "${SERVER_PID}"
SERVER_EXIT=$?
if [ -n "${SHUTDOWN_STARTED:-}" ]; then
  SERVER_EXIT="${SHUTDOWN_EXIT}"
fi
kill "${WATCH_PID}" 2>/dev/null
# A process the server leaves behind could hold the log pipe open, so this wait is bounded.
{ sleep 10; kill -KILL "${LOG_PID}" 2>/dev/null; } &
wait "${LOG_PID}"
rm -f "${SERVER_CONSOLE}" "${SERVER_PID_FILE}" "${CVARLIST}.tmp"
exit "${SERVER_EXIT}"
