#!/bin/bash
# Boots an image on a game branch three times on one volume:
#   1. Sandbox: installs the game, keeps CVAR_ variables and admins written before the first start,
#      answers server queries, lists its console variables, runs console commands and shuts down
#      through `quit` on docker stop.
#   2. The same container again: checks for a game update, and CONFIG_STRICT checks the names against
#      the server's own list. A container with a misspelled CVAR_ name must refuse to start.
#   3. A new container running TTT with Counter-Strike: Source mounted.
# Writes the env reference for the docs site to <out dir>/<branch>-<build id>.json, with the image
# version from its org.opencontainers.image.version label.
# Usage: boot_test.sh <image> <game branch> <out dir>

set -euo pipefail
# `docker logs | grep -q` would fail under pipefail: grep stops at the first match and docker logs
# dies of SIGPIPE. Those checks use grep >/dev/null instead.

image="$1"
branch="$2"
out_dir="$3"
name="gmod-boot-test"
# Kept after the test, so a failed run can be inspected.
volume="gmod-boot-server"
dir="/home/steam/gmod-dedicated"
work="$(mktemp -d)"
release="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "${image}")"
if [ -z "${release}" ] || [ "${release}" = "<no value>" ]; then
  echo "Error: ${image} has no org.opencontainers.image.version label" >&2
  exit 1
fi

fail() {
  echo "Error: $*" >&2
  # The start of the log has the game install and the configuration, the end what the server did last.
  docker logs "${name}" 2>&1 | sed -n '1,150p' >&2 || true
  echo "[...]" >&2
  docker logs --tail 150 "${name}" >&2 || true
  exit 1
}
trap 'docker rm -f "${name}" >/dev/null 2>&1 || true; rm -rf "${work}"' EXIT

start_server() {
  # Starts a new container on the volume; the arguments are more docker run options.
  docker rm -f "${name}" >/dev/null 2>&1 || true
  docker run -d --name "${name}" --health-interval=5s -v "${volume}:${dir}" \
    -e GAME_BRANCH="${branch}" -e CVAR_hostname="Boot test" -e CONFIG_STRICT=true "$@" "${image}" >/dev/null
}

wait_healthy() {
  # The install comes first and can take long; once the server starts, it has 5 minutes.
  local status="" started=""
  echo "Waiting for the server to answer queries"
  for _ in $(seq 1 240); do
    status="$(docker inspect -f '{{.State.Health.Status}}' "${name}")"
    [ "${status}" = healthy ] && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "${name}")" = true ] || fail "the server exited before it started"
    if [ -z "${started}" ] && docker logs "${name}" 2>&1 | grep '^Server: starting' >/dev/null; then
      started="${SECONDS}"
    fi
    [ -n "${started}" ] && [ $((SECONDS - started)) -gt 300 ] && break
    sleep 5
  done
  # The open UDP ports (hex, in /proc/net/udp), and the raw answers on loopback and the container's
  # own address.
  docker exec "${name}" bash -c '
    cat /proc/net/udp
    for host in 127.0.0.1 $(hostname -I); do
      exec 3<>"/dev/udp/${host}/${PORT:-27015}"
      printf "\xff\xff\xff\xffTSource Engine Query\x00" >&3
      echo "Answer from ${host}: $(timeout 2 dd bs=4096 count=1 status=none <&3 | od -An -v -tx1 | tr -d " \n" | head -c 120)"
      exec 3<&-
    done' >&2 || true
  fail "the server did not answer queries"
}

wait_cvarlist() {
  # The server lists its console variables a few seconds after it answers queries.
  for _ in $(seq 1 30); do
    docker logs "${name}" 2>&1 | grep '^Server: listed [0-9]* console variables' >/dev/null && return 0
    sleep 2
  done
  fail "the server did not list its console variables; the log should show what became of the cvarlist output"
}

info() {
  # $1 = field of server-info
  docker exec "${name}" server-info | sed -n "s/^$1=//p"
}

lua() {
  # $1 = Lua expression; prints its value, as the server prints it in the log after `console lua_run`.
  # The marker is joined in Lua, so the echo of the command itself doesn't match.
  local marker="bootcheck${RANDOM}" value=""
  docker exec "${name}" console "lua_run print(\"${marker:0:5}\" .. \"${marker:5}=\" .. tostring($1))" >/dev/null
  for _ in $(seq 1 15); do
    value="$(docker logs "${name}" 2>&1 | sed -n "s/^.*${marker}=//p" | tail -n 1)"
    [ -n "${value}" ] && { printf '%s' "${value}"; return 0; }
    sleep 1
  done
  fail "lua_run got no answer in the log, so the server doesn't read the console FIFO"
}

stop_server() {
  # $1 = how many clean stops the log of this container should show by now
  echo "Stopping the server"
  docker stop -t 30 "${name}" >/dev/null
  exit_code="$(docker inspect -f '{{.State.ExitCode}}' "${name}")"
  [ "${exit_code}" = 0 ] || fail "the server exited with ${exit_code} on docker stop instead of quitting cleanly"
  [ "$(docker logs "${name}" 2>&1 | grep -c "Server stopped with exit code 0")" = "$1" ] || fail "the shutdown did not go through quit"
}

expect() {
  # $1 = what is checked, $2 = actual, $3 = expected
  [ "$2" = "$3" ] || fail "$1 is '$2' instead of '$3'"
}

echo "Start 1: sandbox"
start_server -e MAXPLAYERS=12 -e SUPERADMINS="76561197960287930" -e CVAR_sv_allowcslua=0
wait_healthy

game_lines="$(docker logs "${name}" 2>&1 | grep 'Game: ' || true)"
build="$(sed -n "s/^Game: ${branch} branch, build \([0-9][0-9]*\)$/\1/p" <<< "${game_lines}" | tail -n 1)"
[ -n "${build}" ] || fail "the log does not say which build of the ${branch} branch was installed. Its lines with 'Game: ' are:
${game_lines:-none}"
version="$(docker exec "${name}" sed -n 's/^PatchVersion=\([0-9.]*\).*/\1/p' "${dir}/garrysmod/steam.inf" 2>/dev/null | head -n 1 || true)"
case "${branch}" in
  public) channel=stable ;;
  *) channel="(${branch} branch)" ;;
esac
label="${version:-build ${build}} ${channel}"
echo "Installed ${label}, build ${build}, $(docker logs "${name}" 2>&1 | sed -n 's/^Server: starting \([^ ]*\).*/\1/p' | tail -n 1)"

expect "the server name" "$(info name)" "Boot test"
expect "the map" "$(info map)" "gm_construct"
expect "the game folder" "$(info folder)" "garrysmod"
expect "the player slots" "$(info players)" "0/12"
gamemode="$(lua 'engine.ActiveGamemode()')"
expect "the gamemode" "${gamemode}" "sandbox"
docker exec "${name}" grep -qF '"STEAM_0:0:11101"' "${dir}/garrysmod/settings/users.txt" \
  || fail "SUPERADMINS was not written to settings/users.txt"
# The image only writes users.txt; the base gamemode is what reads it.
docker exec "${name}" grep -rqF 'settings/users.txt' "${dir}/garrysmod/lua" \
  || echo "::warning title=users.txt::No Lua file of the game mentions settings/users.txt any more, so SUPERADMINS and ADMINS may do nothing"

wait_cvarlist
docker exec "${name}" list-env --tsv > "${work}/sandbox.tsv"
for row in CVAR_hostname CVAR_sv_allowcslua CVAR_sv_password; do
  grep -q "^cvar	${row}	" "${work}/sandbox.tsv" || fail "list-env does not list ${row}"
done
grep -q "^cvar	CVAR_hostname	Boot test	" "${work}/sandbox.tsv" || fail "list-env does not show the hostname from server.cfg"
# Console variables ignore case, so names that differ only in case would be the same variable.
duplicates="$(cut -f2 "${work}/sandbox.tsv" | tr '[:upper:]' '[:lower:]' | sort | uniq -d)"
[ -z "${duplicates}" ] || fail "list-env produced duplicate names: ${duplicates}"
echo "list-env lists $(grep -c '^cvar' "${work}/sandbox.tsv") console variables"
stop_server 1

echo "Start 2: the same container, with CONFIG_STRICT checking against the server's list"
docker start "${name}" >/dev/null
wait_healthy
[ "$(docker logs "${name}" 2>&1 | grep -c "^Game: ${branch} branch, build ")" = 2 ] \
  || fail "the second start did not check the game for updates"
[ "$(docker logs "${name}" 2>&1 | grep -c "^Config: CVAR_ names are checked from the next start")" = 1 ] \
  || fail "the second start did not check the CVAR_ names"
expect "the server name after a restart" "$(info name)" "Boot test"
stop_server 2

if output="$(docker run --rm -v "${volume}:${dir}" -e GAME_BRANCH="${branch}" -e GAME_UPDATE=false \
  -e CVAR_hostnmae=typo -e CONFIG_STRICT=true "${image}" 2>&1)"; then
  fail "a misspelled CVAR_ name did not stop the start with CONFIG_STRICT"
fi
grep -q 'match no console variable.*CVAR_hostnmae' <<< "${output}" \
  || fail "the misspelled CVAR_ name was not reported. The output was:
${output}"

echo "Start 3: TTT with Counter-Strike: Source mounted"
start_server -e GAMEMODE=terrortown -e GAME_MOUNTS=cstrike -e CVAR_ttt_preptime_seconds=5
wait_healthy
docker logs "${name}" 2>&1 | grep '^Mount: cstrike, build [0-9]' >/dev/null || fail "the log does not show the Counter-Strike: Source install"
gamemode="$(lua 'engine.ActiveGamemode()')"
expect "the gamemode" "${gamemode}" "terrortown"
mounted="$(lua 'IsMounted("cstrike")')"
expect "the cstrike mount" "${mounted}" "true"
preptime="$(lua 'GetConVar("ttt_preptime_seconds"):GetInt()')"
expect "ttt_preptime_seconds" "${preptime}" "5"
wait_cvarlist
docker exec "${name}" list-env --tsv > "${work}/terrortown.tsv"
grep -q "^cvar	CVAR_ttt_preptime_seconds	5	" "${work}/terrortown.tsv" || fail "list-env does not list the TTT console variables"
stop_server 1

# Variables in both lists come from the engine or the base gamemode; the others belong to one gamemode.
mkdir -p "${out_dir}"
jq -n --arg label "${label}" --arg release "${release}" \
  --rawfile sandbox "${work}/sandbox.tsv" --rawfile terrortown "${work}/terrortown.tsv" '
  def rows($tsv): $tsv | split("\n") | map(select(length > 0) | split("\t") | {kind: .[0], name: .[1], description: (.[3] // "")});
  (rows($sandbox)) as $s
  | (rows($terrortown) | map(select(.kind == "cvar"))) as $t
  | ($s | map({key: .name, value: true}) | from_entries) as $in_s
  | ($t | map({key: .name, value: true}) | from_entries) as $in_t
  | {label: $label, release: $release, vars: (
      ($s | map(if .kind == "cvar" and ($in_t[.name] | not) then . + {gamemode: "sandbox"} else . end))
      + ($t | map(select($in_s[.name] | not) | . + {gamemode: "terrortown"}))
    )}
' > "${out_dir}/${branch}-${build}.json"
echo "Boot test passed"
