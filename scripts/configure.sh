#!/bin/bash
# Applies the environment to the server's config files and builds ARGS. Sourced by entry.sh.

# shellcheck source=scripts/lib/config.sh
. "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=scripts/lib/admins.sh
. "${SCRIPT_DIR}/lib/admins.sh"
# shellcheck source=scripts/lib/game.sh
. "${SCRIPT_DIR}/lib/game.sh"
# shellcheck source=scripts/lib/args.sh
. "${SCRIPT_DIR}/lib/args.sh"

configure_server() {
  local cfg_dir="${STEAMAPPDIR}/garrysmod/cfg"

  report_unrecognized "${SCRIPT_DIR}/image-env"
  report_overlaps

  mkdir -p "${cfg_dir}"
  [ -f "${cfg_dir}/server.cfg" ] || touch "${cfg_dir}/server.cfg"
  apply_cvar_env "${cfg_dir}/server.cfg"
  apply_mount_cfg "${cfg_dir}/mount.cfg"
  apply_admins "${STEAMAPPDIR}/garrysmod/settings/users.txt"
  build_server_args
}
