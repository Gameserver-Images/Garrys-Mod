#!/bin/bash
# Tests the startup scripts against fixture files, a fake SteamCMD and a stub server.
# Run: bash smoke/run_smoke.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${REPO}/scripts"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
FAILED=0

fail() { echo "FAIL [${TEST}]: $*" >&2; FAILED=1; }
expect_line() {
  # $1 = file, $2 = exact line
  grep -qxF -- "$2" "$1" || fail "expected line '$2' in $(basename "$1")"
}
expect_eq() {
  [ "$1" = "$2" ] || fail "expected '$2', got '$1'"
}

# Each test runs in a subshell with a fresh fake HOMEDIR/STEAMAPPDIR and no CVAR_ leftovers.
new_env() {
  rm -rf "${WORK:?}/home"
  export HOMEDIR="${WORK}/home" STEAMAPPDIR="${WORK}/home/gmod-dedicated" STEAMAPPID=4020
  CFG="${STEAMAPPDIR}/garrysmod/cfg"
  mkdir -p "${CFG}"
  cp "${REPO}/smoke/fixtures/server.cfg" "${CFG}/server.cfg"
  { echo "# gamemode=sandbox workshop="; cat "${REPO}/smoke/fixtures/cvarlist.txt"; } > "${STEAMAPPDIR}/.cvarlist"
  export STEAMCMDDIR="${WORK}/home/steamcmd"
  mkdir -p "${STEAMCMDDIR}"
  # Logs its arguments and installs a fake app with build FAKE_BUILD. Like the real one, its output
  # doesn't end with a newline.
  cat > "${STEAMCMDDIR}/steamcmd.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${HOMEDIR}/steamcmd-calls"
app="$6"
[ -n "${FAKE_STEAM_FAIL:-}" ] && { echo "ERROR! Failed to install app '${app}' (No connection)"; exit 8; }
[ -n "${FAKE_STEAM_SILENT:-}" ] && exit 0
dir="$2"
mkdir -p "${dir}/steamapps"
[ -f "${dir}/srcds_run" ] || printf '#!/bin/bash\n' > "${dir}/srcds_run"
chmod +x "${dir}/srcds_run"
printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"buildid"\t\t"%s"\n}\n' "${app}" "${FAKE_BUILD:-100}" > "${dir}/steamapps/appmanifest_${app}.acf"
printf "Success! App '%s' fully installed.\nUnloading Steam API...OK" "${app}"
EOF
  chmod +x "${STEAMCMDDIR}/steamcmd.sh"
  # shellcheck source=scripts/configure.sh
  . "${SCRIPT_DIR}/configure.sh"
}

test_cvars() {
  TEST=cvars
  new_env
  local cfg="${CFG}/server.cfg"
  echo 'rcon from file' > "${WORK}/rcon"
  export CVAR_hostname='My "best" server' CVAR_HOSTNAME=x CVAR_SBOX_MAXPROPS=300 CVAR_sv_loadingurl='http://example.com/load?a=1&b=2' \
    CVAR_rcon_password=ignored CVAR_rcon_password_FILE="${WORK}/rcon" CVAR_not_a_cvar=1 CVAR__restart=1
  unset CVAR_HOSTNAME
  apply_cvar_env "${cfg}" > /dev/null 2> "${WORK}/err"
  expect_line "${cfg}" 'hostname "My server"'
  grep -q 'double quote.*CVAR_hostname' "${WORK}/err" || fail "a value with a quote was not reported"
  grep -q 'match no console variable.* CVAR__restart CVAR_not_a_cvar' "${WORK}/err" || fail "unknown names and commands were not reported"
  grep -q 'not_a_cvar\|_restart' "${cfg}" && fail "an unknown name was written"
  (CONFIG_STRICT=true apply_cvar_env "${cfg}" > /dev/null 2>&1) && fail "CONFIG_STRICT did not stop on an unknown name"
  unset CVAR_not_a_cvar CVAR__restart

  CVAR_hostname='My best server & co | $HOME \x' apply_cvar_env "${cfg}" > /dev/null 2> "${WORK}/err"
  [ -s "${WORK}/err" ] && { fail "valid names were reported"; cat "${WORK}/err" >&2; }
  expect_eq "$(cat "${cfg}")" '// Written by hand
hostname "My best server & co | $HOME \x"
sv_password ""
SBOX_MAXPROPS "300"
exec banned_user.cfg
rcon_password "rcon from file"
sv_loadingurl "http://example.com/load?a=1&b=2"'

  # The list was made with another gamemode, so nothing can be checked and every name is written.
  GAMEMODE=terrortown CVAR_ttt_preptime_seconds=5 apply_cvar_env "${cfg}" > "${WORK}/out" 2>&1
  expect_line "${cfg}" 'ttt_preptime_seconds "5"'
  grep -q 'checked from the next start' "${WORK}/out" || fail "unchecked names were not mentioned"
  rm "${STEAMAPPDIR}/.cvarlist"
  CVAR_another=1 apply_cvar_env "${cfg}" > /dev/null 2>&1
  expect_line "${cfg}" 'another "1"'
}

test_admins() {
  TEST=admins
  new_env
  local users="${STEAMAPPDIR}/garrysmod/settings/users.txt"
  SUPERADMINS='STEAM_1:0:11101; 76561197960287930;;[U:1:47]' apply_admins "${users}" > /dev/null 2> "${WORK}/err"
  [ -s "${WORK}/err" ] && fail "valid SteamIDs were reported"
  expect_eq "$(cat "${users}")" "$(printf '"Users"\n{\n\t"superadmin"\n\t{\n\t\t"STEAM_0:0:11101"\t"STEAM_0:0:11101"\n\t\t"STEAM_0:0:11101"\t"STEAM_0:0:11101"\n\t\t"STEAM_0:1:23"\t"STEAM_0:1:23"\n\t}\n\t"admin"\n\t{\n\t}\n}')"

  ADMINS='bogus;STEAM_0:1:23;76561197960265728' apply_admins "${users}" > /dev/null 2> "${WORK}/err"
  grep -q 'not SteamIDs.* ADMINS:bogus ADMINS:76561197960265728' "${WORK}/err" || fail "invalid SteamIDs were not reported"
  expect_eq "$(cat "${users}")" "$(printf '"Users"\n{\n\t"superadmin"\n\t{\n\t}\n\t"admin"\n\t{\n\t\t"STEAM_0:1:23"\t"STEAM_0:1:23"\n\t}\n}')"
  (ADMINS=bogus CONFIG_STRICT=true apply_admins "${users}" > /dev/null 2>&1) && fail "CONFIG_STRICT did not stop on an invalid SteamID"

  echo "by hand" > "${users}"
  apply_admins "${users}" > /dev/null
  expect_eq "$(cat "${users}")" "by hand"
}

test_mounts() {
  TEST=mounts
  new_env
  # The retries would otherwise wait 10 seconds each.
  sleep() { :; }
  local mount_cfg="${CFG}/mount.cfg" calls="${HOMEDIR}/steamcmd-calls"
  GAME_MOUNTS=' cstrike ;tf;' update_mounts > "${WORK}/out" 2>&1 || fail "installing the mounts failed"
  expect_line "${calls}" "+force_install_dir ${STEAMAPPDIR}/mounts/cstrike +login anonymous +app_update 232330 +quit"
  expect_line "${calls}" "+force_install_dir ${STEAMAPPDIR}/mounts/tf +login anonymous +app_update 232250 +quit"
  expect_line "${WORK}/out" "Mount: cstrike, build 100"
  GAME_MOUNTS=cstrike GAME_UPDATE=false update_mounts > "${WORK}/out" 2>&1
  expect_eq "$(wc -l < "${calls}")" 2
  expect_line "${WORK}/out" "Mount: cstrike, build 100, not checked for updates (GAME_UPDATE=false)"
  (GAME_MOUNTS='cstrike;portal' update_mounts > /dev/null 2> "${WORK}/err") && fail "an unknown game did not stop the start"
  grep -q 'portal, which this image can.t mount. It can mount: cstrike hl2mp dod tf' "${WORK}/err" || fail "the mountable games were not listed"
  (FAKE_STEAM_FAIL=1 GAME_MOUNTS=hl2mp update_mounts > /dev/null 2>&1) && fail "a failed mount install did not stop the start"

  GAME_MOUNTS='cstrike' apply_mount_cfg "${mount_cfg}" > "${WORK}/out"
  expect_eq "$(cat "${mount_cfg}")" "$(printf '"mountcfg"\n{\n\t"cstrike"\t"%s/mounts/cstrike/cstrike"\n}' "${STEAMAPPDIR}")"
  grep -q 'tf is installed in mounts/tf but not mounted' "${WORK}/out" || fail "an unmounted install was not mentioned"
  GAME_MOUNTS='' apply_mount_cfg "${mount_cfg}" > /dev/null
  expect_eq "$(cat "${mount_cfg}")" "$(printf '"mountcfg"\n{\n}')"
  echo "by hand" > "${mount_cfg}"
  apply_mount_cfg "${mount_cfg}" > /dev/null
  expect_eq "$(cat "${mount_cfg}")" "by hand"
}

test_overlaps() {
  TEST=overlaps
  new_env
  export GAMEMODE=sandbox CVAR_Gamemode=x PORT=1 CVAR_hostport=2 CVAR_hostname=a CVAR_hostname_FILE=/x \
    CVAR_sv_password=a CVAR_SV_PASSWORD=b STEAM_GSLT=a STEAM_GSLT_FILE=/y MAXPLAYERS=4
  report_overlaps 2> "${WORK}/err"
  grep -q 'GAMEMODE and CVAR_Gamemode set the same thing; remove CVAR_Gamemode' "${WORK}/err" || fail "GAMEMODE overlap not reported"
  grep -q 'PORT and CVAR_hostport set the same thing' "${WORK}/err" || fail "PORT overlap not reported"
  grep -q 'CVAR_hostname and CVAR_hostname_FILE are both set' "${WORK}/err" || fail "_FILE overlap not reported"
  grep -q 'STEAM_GSLT_FILE is used' "${WORK}/err" || fail "STEAM_GSLT overlap not reported"
  grep -q 'differ only in case' "${WORK}/err" || fail "case duplicate not reported"
  expect_eq "$(wc -l < "${WORK}/err")" 5
}

test_unrecognized() {
  TEST=unrecognized
  new_env
  # Everything the test runner itself exports counts as the image's own, except what bash adds.
  compgen -e | grep -vxE 'OLDPWD|PWD|SHLVL' > "${WORK}/image-env"
  export HOSTNAME_=x CVARS_hostname=x GAMEMODE=sandbox CVAR_hostname=x http_proxy=x TZ=UTC
  report_unrecognized "${WORK}/image-env" 2> "${WORK}/err"
  grep -q 'does not read CVARS_hostname HOSTNAME_\.' "${WORK}/err" || { fail "unknown variables were not reported as expected"; cat "${WORK}/err" >&2; }
  unset HOSTNAME_ CVARS_hostname
  report_unrecognized "${WORK}/image-env" 2> "${WORK}/err"
  [ -s "${WORK}/err" ] && fail "known variables were reported"
}

test_configure() {
  TEST=configure
  new_env
  configure_server > /dev/null 2>&1
  expect_eq "${ARGS[*]}" "-game garrysmod -norestart +maxplayers 16 +gamemode sandbox +map gm_construct"
  [ -e "${STEAMAPPDIR}/garrysmod/settings/users.txt" ] && fail "users.txt was written without SUPERADMINS or ADMINS"
  [ -e "${CFG}/mount.cfg" ] && fail "mount.cfg was written without GAME_MOUNTS"

  echo 'token from file' > "${WORK}/token"
  export IP=10.0.0.2 PORT=27016 TICKRATE=33 STEAM_API_KEY=key STEAM_GSLT=ignored STEAM_GSLT_FILE="${WORK}/token" MAXPLAYERS=24 \
    WORKSHOP_COLLECTION=123 SERVER_ARGS=' -disableluarefresh  +sv_lan 0 ' GAMEMODE=terrortown MAP=ttt_minecraft_b5 GAME_MOUNTS=cstrike
  configure_server > /dev/null 2>&1
  expect_eq "$(printf '%q ' "${ARGS[@]}")" "-game garrysmod -norestart -ip 10.0.0.2 -port 27016 -tickrate 33 -authkey key +sv_setsteamaccount token\\ from\\ file +maxplayers 24 +host_workshop_collection 123 -disableluarefresh +sv_lan 0 +gamemode terrortown +map ttt_minecraft_b5 "
  [ -f "${CFG}/mount.cfg" ] || fail "mount.cfg was not written"
}

test_list_env() {
  TEST="list-env"
  new_env
  export STEAM_GSLT=secret
  set_cfg_value "${CFG}/server.cfg" rcon_password hunter2
  bash "${SCRIPT_DIR}/list_env.sh" > "${WORK}/out"
  expect_line "${WORK}/out" '## Image settings'
  expect_line "${WORK}/out" '## Console variables (garrysmod/cfg/server.cfg)'
  expect_line "${WORK}/out" 'STEAM_GSLT=(set)'
  expect_line "${WORK}/out" '# Hostname for server.'
  expect_line "${WORK}/out" 'CVAR_hostname=My server'
  expect_line "${WORK}/out" 'CVAR_sbox_maxprops=120'
  expect_line "${WORK}/out" 'CVAR_sv_password='
  expect_line "${WORK}/out" 'CVAR_rcon_password=(set)'
  expect_line "${WORK}/out" 'CVAR_sv_allowcslua='
  expect_line "${WORK}/out" '# URL of the loading screen : shown while joining'
  grep -q 'CVAR_kick\|CVAR__restart' "${WORK}/out" && fail "commands were listed"
  bash "${SCRIPT_DIR}/list_env.sh" password > "${WORK}/out"
  grep -q '^GAME_' "${WORK}/out" && fail "the filter kept unrelated rows"
  grep -q '^CVAR_sv_password=' "${WORK}/out" || fail "the filter dropped matching rows"
  bash "${SCRIPT_DIR}/list_env.sh" --tsv > "${WORK}/out"
  expect_line "${WORK}/out" "$(printf 'cvar\tCVAR_hostport\t\tHost game server port')"
  expect_eq "$(grep -c '^cvar' "${WORK}/out")" 9
  rm "${STEAMAPPDIR}/.cvarlist"
  bash "${SCRIPT_DIR}/list_env.sh" > "${WORK}/out" 2> "${WORK}/err"
  grep -q '^CVAR_' "${WORK}/out" && fail "cvars were listed without a cvar list"
  grep -q 'once it is up' "${WORK}/err" || fail "the missing cvar list was not explained"
}

test_vars_documented() {
  TEST=vars
  local name
  while IFS=$'\t' read -r name _; do
    grep -rq --include='*.sh' -- "${name}" "${SCRIPT_DIR}" || fail "${name} is documented but never read"
  done < "${SCRIPT_DIR}/vars.tsv"
  for name in $(grep -rhoE '\$\{[A-Z][A-Z0-9_]+(:-|\+x|\})' "${SCRIPT_DIR}" | grep -oE '[A-Z][A-Z0-9_]+' | sort -u); do
    case "${name}" in
      HOMEDIR|STEAMAPPDIR|STEAMAPPID|STEAMCMDDIR|SCRIPT_DIR|SERVER_CONSOLE|SERVER_PID|SERVER_PID_FILE|SERVER_EXIT|SHUTDOWN_*|CONSOLE_FD|ARGS|LOG_*|WATCH_PID|CVARLIST|MOUNTABLE_GAMES) continue ;;
    esac
    grep -q "^${name}	" "${SCRIPT_DIR}/vars.tsv" || fail "${name} is read but not in vars.tsv"
  done
}

test_game() {
  TEST=game
  new_env
  sleep() { :; }
  local calls="${HOMEDIR}/steamcmd-calls"
  update_game > "${WORK}/out" 2>&1 || fail "the first install failed"
  expect_line "${calls}" "+force_install_dir ${STEAMAPPDIR} +login anonymous +app_update 4020 +quit"
  expect_line "${STEAMAPPDIR}/.game-branch" public
  expect_line "${WORK}/out" "Game: public branch, build 100"

  FAKE_BUILD=101 update_game > "${WORK}/out" 2>&1
  expect_line "${WORK}/out" "Game: public branch, build 101"
  expect_eq "$(wc -l < "${calls}")" 2

  GAME_UPDATE=false update_game > "${WORK}/out" 2>&1
  expect_eq "$(wc -l < "${calls}")" 2
  expect_line "${WORK}/out" "Game: public branch, build 101, not checked for updates (GAME_UPDATE=false)"

  # A branch change goes through even with GAME_UPDATE=false, and SteamCMD has to forget the old beta.
  GAME_BRANCH=x86-64 GAME_UPDATE=false update_game > /dev/null 2>&1
  expect_eq "$(tail -n 1 "${calls}")" "+force_install_dir ${STEAMAPPDIR} +login anonymous +app_update 4020 -beta x86-64 validate +quit"
  expect_line "${STEAMAPPDIR}/.game-branch" x86-64
  GAME_BRANCH=x86-64 update_game > /dev/null 2>&1
  expect_eq "$(tail -n 1 "${calls}")" "+force_install_dir ${STEAMAPPDIR} +login anonymous +app_update 4020 -beta x86-64 +quit"

  # Without its success line SteamCMD failed, whatever its exit code. The switch back to public has
  # already dropped the beta's manifest by then.
  (FAKE_STEAM_SILENT=1 update_game > /dev/null 2> "${WORK}/err") && fail "a silent SteamCMD run counted as an update"
  [ -f "${STEAMAPPDIR}/steamapps/appmanifest_4020.acf" ] && fail "the switch back to public kept the beta's manifest"
  expect_eq "$(tail -n 1 "${calls}")" "+force_install_dir ${STEAMAPPDIR} +login anonymous +app_update 4020 validate +quit"
  expect_line "${STEAMAPPDIR}/.game-branch" x86-64

  update_game > /dev/null 2>&1
  expect_line "${STEAMAPPDIR}/.game-branch" public
  (FAKE_STEAM_FAIL=1 update_game > /dev/null 2> "${WORK}/err") && fail "a failed update did not stop the start"
  expect_eq "$(tail -n 3 "${calls}" | grep -c '+app_update 4020 +quit')" 3
  grep -q 'GAME_UPDATE=false starts the installed game' "${WORK}/err" || fail "the GAME_UPDATE hint was missing"
}

test_server_info() {
  TEST="server-info"
  if ! command -v python3 > /dev/null; then
    echo "SKIP [${TEST}]: needs python3 for the fake server"
    return 0
  fi
  local port
  # A fake server that asks for a challenge first, as current Source servers do.
  python3 - > "${WORK}/port" <<'EOF' &
import socket, struct, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", 0))
s.settimeout(10)
print(s.getsockname()[1], flush=True)
query = b"\xff\xff\xff\xffTSource Engine Query\x00"
for _ in range(2):
    data, addr = s.recvfrom(1400)
    if data == query:
        s.sendto(b"\xff\xff\xff\xffA\x01\x00\x02\x03", addr)
    elif data == query + b"\x01\x00\x02\x03":
        info = b"\xff\xff\xff\xffI\x11" + "Boot test & co ✓".encode() + b"\x00gm_construct\x00garrysmod\x00Sandbox\x00"
        info += struct.pack("<HBBBccBB", 4000, 3, 16, 1, b"d", b"l", 0, 1) + b"2024.01.01\x00"
        s.sendto(info, addr)
EOF
  for _ in $(seq 1 50); do
    [ -s "${WORK}/port" ] && break
    sleep 0.1
  done
  port="$(cat "${WORK}/port")"
  IP=127.0.0.1 PORT="${port}" bash "${SCRIPT_DIR}/server_info.sh" > "${WORK}/out" 2> "${WORK}/err" || { fail "the query failed"; cat "${WORK}/err" >&2; }
  expect_eq "$(cat "${WORK}/out")" "name=Boot test & co ✓
map=gm_construct
folder=garrysmod
gamemode=Sandbox
players=3/16
bots=1"
  wait
  # Nothing listens on the port any more.
  IP=127.0.0.1 PORT="${port}" timeout 5 bash "${SCRIPT_DIR}/server_info.sh" > /dev/null 2> "${WORK}/err" && fail "a query without a server succeeded"
  grep -q "no answer from 127.0.0.1:${port}" "${WORK}/err" || fail "the missing answer was not explained"
}

test_entry() {
  TEST=entry
  new_env
  # The stub server "answers queries" once it has created this file.
  cp -r "${SCRIPT_DIR}" "${WORK}/scripts"
  printf '#!/bin/bash\n[ -f "${HOMEDIR}/listening" ]\n' > "${WORK}/scripts/server_info.sh"
  chmod +x "${WORK}/scripts/server_info.sh"
  rm -f "${STEAMAPPDIR}/.cvarlist"
  cat > "${STEAMAPPDIR}/srcds_run" <<EOF
#!/bin/bash
# The real server blocks on a console that isn't a terminal.
[ -t 0 ] && [ -t 1 ] || { echo "the console is not a terminal"; exit 3; }
printf '%s\n' "\$@" > "\${HOMEDIR}/args"
echo "Loading map gm_construct"
printf '\\e[38;2;156;241;255mcoloured\\e[39m\\e[38;2;156;241;255m\\n'
touch "\${HOMEDIR}/listening"
while IFS= read -r line; do
  case "\${line}" in
    quit) echo "shutting down"; sleep 0.2; echo "bye"; exit 0 ;;
    cvarlist) cat "${REPO}/smoke/fixtures/cvarlist.txt" ;;
    *) echo "command: \${line}" ;;
  esac
done
EOF
  chmod +x "${STEAMAPPDIR}/srcds_run"
  (cd "${WORK}" && exec bash "${WORK}/scripts/entry.sh") > "${WORK}/entry.log" 2>&1 &
  local pid=$! listed=false
  for _ in $(seq 1 100); do
    [ -f "${STEAMAPPDIR}/.cvarlist" ] && { listed=true; break; }
    sleep 0.1
  done
  [ "${listed}" = true ] || { fail "the cvar list was never saved"; cat "${WORK}/entry.log" >&2; }
  bash "${WORK}/scripts/healthcheck.sh" || fail "the health check failed"
  expect_eq "$(head -n 1 "${STEAMAPPDIR}/.cvarlist")" "# gamemode=sandbox workshop="
  expect_eq "$(tail -n +2 "${STEAMAPPDIR}/.cvarlist" | cvar_rows | wc -l)" 9
  sleep 0.2
  expect_line "${WORK}/entry.log" "Server: listed 9 console variables for list-env and the CVAR_ checks"
  grep -q 'hostname \| total convars\|^cvar list\|^---' "${WORK}/entry.log" && fail "the cvar list went to the log"
  expect_line "${WORK}/entry.log" "coloured"
  bash "${WORK}/scripts/console.sh" lua_run 'print("a b")' > /dev/null || fail "console failed"
  sleep 0.2
  expect_line "${WORK}/entry.log" 'command: lua_run print("a b")'
  kill -TERM "${pid}"
  wait "${pid}"
  expect_eq "$?" 0
  grep -q 'shutting down' "${WORK}/entry.log" || fail "the server did not receive quit"
  grep -q bye "${WORK}/entry.log" || fail "the last server output was lost"
  bash "${WORK}/scripts/console.sh" status > /dev/null 2>&1 && fail "console worked after the server stopped"
  expect_line "${HOMEDIR}/args" "-norestart"
  expect_line "${HOMEDIR}/args" "+gamemode"
}

for t in test_cvars test_admins test_mounts test_overlaps test_unrecognized test_configure test_list_env test_vars_documented test_game test_server_info test_entry; do
  ( "${t}"; exit "${FAILED}" ) || FAILED=1
done

if [ "${FAILED}" -ne 0 ]; then
  echo "Smoke tests failed" >&2
  exit 1
fi
echo "Smoke tests passed"
