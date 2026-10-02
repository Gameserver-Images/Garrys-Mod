#!/bin/bash
# Builds the srcds_run argument list.

build_server_args() {
  local token key extra=()
  ARGS=(-game garrysmod -norestart)
  [ -n "${IP:-}" ] && ARGS+=(-ip "${IP}")
  [ -n "${PORT:-}" ] && ARGS+=(-port "${PORT}")
  [ -n "${TICKRATE:-}" ] && ARGS+=(-tickrate "${TICKRATE}")
  key="$(read_secret STEAM_API_KEY STEAM_API_KEY_FILE)"
  [ -n "${key}" ] && ARGS+=(-authkey "${key}")
  token="$(read_secret STEAM_GSLT STEAM_GSLT_FILE)"
  [ -n "${token}" ] && ARGS+=(+sv_setsteamaccount "${token}")
  ARGS+=(+maxplayers "${MAXPLAYERS:-16}")
  [ -n "${WORKSHOP_COLLECTION:-}" ] && ARGS+=(+host_workshop_collection "${WORKSHOP_COLLECTION}")
  # Before +map, so their + commands run before the map loads.
  read -ra extra <<< "${SERVER_ARGS:-}"
  ARGS+=("${extra[@]}")
  ARGS+=(+gamemode "${GAMEMODE:-sandbox}" +map "${MAP:-gm_construct}")
}
