#!/bin/bash
# Installs the game into STEAMAPPDIR from the Steam branch in GAME_BRANCH, and the games in
# GAME_MOUNTS into STEAMAPPDIR/mounts, and keeps them up to date.

# Games whose dedicated server carries content Garry's Mod can mount: folder name, Steam app ID.
MOUNTABLE_GAMES="cstrike 232330
hl2mp 232370
dod 232290
tf 232250"

app_build() {
  # $1 = install dir, $2 = app ID
  sed -n 's/^[[:space:]]*"buildid"[[:space:]]*"\([0-9]*\)".*/\1/p' \
    "$1/steamapps/appmanifest_$2.acf" 2>/dev/null | head -n 1
}

app_update() {
  # $1 = app ID, $2 = install dir, then more app_update arguments (-beta <branch>, validate).
  # Succeeds once SteamCMD reports success and the dir holds srcds_run, which every Source dedicated
  # server has.
  local app="$1" dir="$2" log status attempt
  shift 2
  log="$(mktemp)"
  # SteamCMD can fail the first attempt with "Missing configuration" until the app info is cached.
  for attempt in 1 2 3; do
    # In the background, so a stop signal doesn't wait for a download to finish.
    (
      set -o pipefail
      "${STEAMCMDDIR}/steamcmd.sh" +force_install_dir "${dir}" +login anonymous \
        +app_update "${app}" "$@" +quit 2>&1 | tee "${log}"
    ) &
    status=0
    wait "$!" || status=$?
    # SteamCMD doesn't end its output with a newline, so the next line would be appended to its last.
    [ -z "$(tail -c 1 "${log}")" ] || echo
    if [ "${status}" = 0 ] && grep -q "Success! App '${app}'" "${log}" && [ -f "${dir}/srcds_run" ]; then
      rm -f "${log}"
      return 0
    fi
    [ "${attempt}" = 3 ] || sleep 10
  done
  rm -f "${log}"
  return 1
}

update_game() {
  local branch="${GAME_BRANCH:-public}" marker="${STEAMAPPDIR}/.game-branch" installed=""
  local beta_args=() validate=()
  [ -f "${marker}" ] && installed="$(<"${marker}")"

  if [ -f "${STEAMAPPDIR}/srcds_run" ] && [ "${installed}" = "${branch}" ] && ! is_true "${GAME_UPDATE:-true}"; then
    echo "Game: ${branch} branch, build $(app_build "${STEAMAPPDIR}" "${STEAMAPPID}"), not checked for updates (GAME_UPDATE=false)"
    return 0
  fi

  # "-beta public" is not a valid beta, so the flag is only passed for other branches.
  [ "${branch}" = public ] || beta_args=(-beta "${branch}")
  if [ -f "${STEAMAPPDIR}/srcds_run" ] && [ "${installed}" != "${branch}" ]; then
    # Without -beta SteamCMD keeps updating from the beta it last installed, so it has to forget
    # the install and check every file against the new branch.
    echo "Game: switching from the ${installed:-unknown} branch to ${branch}"
    rm -f "${STEAMAPPDIR}/steamapps/appmanifest_${STEAMAPPID}.acf"
    validate=(validate)
  fi

  echo "Game: installing or updating the ${branch} branch with SteamCMD"
  if app_update "${STEAMAPPID}" "${STEAMAPPDIR}" "${beta_args[@]}" "${validate[@]}"; then
    printf '%s\n' "${branch}" > "${marker}"
    echo "Game: ${branch} branch, build $(app_build "${STEAMAPPDIR}" "${STEAMAPPID}")"
    return 0
  fi
  echo "Error: SteamCMD could not install or update the ${branch} branch of the game; its output is above." >&2
  if [ -f "${STEAMAPPDIR}/srcds_run" ] && [ "${installed}" = "${branch}" ]; then
    echo "GAME_UPDATE=false starts the installed game without contacting Steam." >&2
  fi
  exit 1
}

mount_names() {
  # Prints the games in GAME_MOUNTS, one per line.
  tr ';' '\n' <<< "${GAME_MOUNTS:-}" | sed -e 's/[[:space:]]//g' -e '/^$/d'
}

update_mounts() {
  local name app dir
  while IFS= read -r name; do
    app="$(awk -v name="${name}" '$1 == name { print $2 }' <<< "${MOUNTABLE_GAMES}")"
    if [ -z "${app}" ]; then
      echo "Error: GAME_MOUNTS has ${name}, which this image can't mount. It can mount: $(cut -d' ' -f1 <<< "${MOUNTABLE_GAMES}" | paste -sd ' ')" >&2
      exit 1
    fi
    dir="${STEAMAPPDIR}/mounts/${name}"
    if [ -f "${dir}/srcds_run" ] && ! is_true "${GAME_UPDATE:-true}"; then
      echo "Mount: ${name}, build $(app_build "${dir}" "${app}"), not checked for updates (GAME_UPDATE=false)"
      continue
    fi
    echo "Mount: installing or updating ${name} (app ${app}) with SteamCMD"
    if ! app_update "${app}" "${dir}"; then
      echo "Error: SteamCMD could not install or update ${name}; its output is above." >&2
      exit 1
    fi
    echo "Mount: ${name}, build $(app_build "${dir}" "${app}")"
  done < <(mount_names)
}

apply_mount_cfg() {
  # $1 = mount.cfg. Rewritten whenever GAME_MOUNTS is set, so taking a game out unmounts it.
  local file="$1" name dir
  [ -n "${GAME_MOUNTS+x}" ] || return 0
  {
    printf '"mountcfg"\n{\n'
    while IFS= read -r name; do
      printf '\t"%s"\t"%s"\n' "${name}" "${STEAMAPPDIR}/mounts/${name}/${name}"
    done < <(mount_names)
    printf '}\n'
  } > "${file}.tmp" && mv "${file}.tmp" "${file}"
  echo "Config: mount.cfg mounts ${GAME_MOUNTS:-nothing}"
  for dir in "${STEAMAPPDIR}"/mounts/*/; do
    [ -d "${dir}" ] || continue
    name="$(basename "${dir}")"
    mount_names | grep -qxF "${name}" \
      || echo "Mount: ${name} is installed in mounts/${name} but not mounted; delete that folder to free its space"
  done
  return 0
}
