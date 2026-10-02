#!/bin/bash
# Sends a command line to the running server's console, e.g. `console say Restart in 5 minutes` or
# `console 'lua_run print(player.GetCount())'`. The reply appears in the container log.

set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "Usage: console <command>, e.g. console status" >&2
  exit 2
fi
if [ ! -p /tmp/gmod-console ] || ! kill -0 "$(cat /tmp/gmod-server.pid 2>/dev/null)" 2>/dev/null; then
  echo "Error: the server is not running." >&2
  exit 1
fi
printf '%s\n' "$*" > /tmp/gmod-console
echo "Sent: $*  (the reply is in docker logs)"
