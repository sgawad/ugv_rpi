#!/bin/bash
# Print the JupyterLab URL including the login token.
#
# JupyterLab 4 generates a fresh token each time the server starts. Rather than
# digging it out of ugv-jupyter.log, ask the running server for it.

USER_HOME="$(eval echo "~${SUDO_USER:-$USER}")"
VENV="$USER_HOME/ugv_rpi/ugv-env/bin/activate"

if [ ! -f "$VENV" ]; then
    echo "Virtual environment not found at $USER_HOME/ugv_rpi/ugv-env"
    echo "Run scripts/setup.sh first."
    exit 1
fi

source "$VENV"

SERVERS="$(jupyter server list 2>/dev/null | grep -E '^http')"

if [ -z "$SERVERS" ]; then
    echo "No JupyterLab server is running."
    echo "Start it with: systemctl --user start ugv-jupyter.service"
    exit 1
fi

IP="$(hostname -I | awk '{print $1}')"

echo "JupyterLab is running. Open one of these (the token is the password):"
while read -r line; do
    url="${line%% ::*}"
    echo "  local : $url"
    [ -n "$IP" ] && echo "  LAN   : ${url/localhost/$IP}"
done <<< "$SERVERS"
