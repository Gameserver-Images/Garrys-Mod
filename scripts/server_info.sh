#!/bin/bash
# Asks the server for its name, map, gamemode and players, as the server browser does (A2S_INFO).
# Usage: server-info. Fails when the server doesn't answer within 2 seconds.

set -euo pipefail

# srcds ignores queries to 127.0.0.1, so without IP this asks the container's own address, or
# loopback when there's no other.
host="${IP:-}"
if [ -z "${host}" ] || [ "${host}" = 0.0.0.0 ]; then
  host="$(hostname -I | cut -d' ' -f1)"
  host="${host:-127.0.0.1}"
fi
port="${PORT:-27015}"
# 0xFFFFFFFF, 'T', "Source Engine Query\0"
query="ffffffff54536f7572636520456e67696e6520517565727900"

exchange() {
  # $1 = request as hex; prints the reply as hex
  exec 3<>"/dev/udp/${host}/${port}"
  # shellcheck disable=SC2059 # the format is the request's bytes
  printf "$(sed 's/../\\x&/g' <<< "$1")" >&3
  timeout 2 dd bs=4096 count=1 status=none <&3 | od -An -v -tx1 | tr -d ' \n'
  exec 3<&-
}

reply="$(exchange "${query}")"
# Newer servers first answer with a challenge ('A') that the query has to repeat.
if [ "${reply:0:10}" = ffffffff41 ]; then
  reply="$(exchange "${query}${reply:10:8}")"
fi
if [ -z "${reply}" ]; then
  echo "Error: no answer from ${host}:${port}" >&2
  exit 1
fi
if [ "${reply:0:10}" != ffffffff49 ]; then
  echo "Error: unexpected answer from ${host}:${port}: ${reply:0:80}" >&2
  exit 1
fi

# After the header and the protocol byte: four strings, the app ID, then player counts.
i=12
for field in name map folder gamemode; do
  value=""
  while [ "${reply:i:2}" != 00 ]; do
    [ "${i}" -lt "${#reply}" ] || { echo "Error: the answer from ${host}:${port} is cut off" >&2; exit 1; }
    value="${value}\\x${reply:i:2}"
    i=$((i + 2))
  done
  i=$((i + 2))
  printf '%s=%b\n' "${field}" "${value}"
done
i=$((i + 4))
printf 'players=%d/%d\n' "0x${reply:i:2}" "0x${reply:i+2:2}"
printf 'bots=%d\n' "0x${reply:i+4:2}"
