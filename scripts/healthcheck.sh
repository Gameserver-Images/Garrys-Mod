#!/bin/bash
# Healthy while the server answers queries the way it answers the server browser.
exec "$(dirname "$(readlink -f "$0")")/server_info.sh" > /dev/null
