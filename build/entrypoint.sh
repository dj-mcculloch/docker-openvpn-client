#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

cleanup() {
    kill TERM "$openvpn_pid"
    exit 0
}

is_enabled() {
    [[ ${1,,} =~ ^(true|t|yes|y|1|on|enable|enabled)$ ]]
}

CONFIG_FILE=${CONFIG_FILE:=}
KILL_SWITCH=${KILL_SWITCH:=on}
ALLOWED_SUBNETS=${ALLOWED_SUBNETS:=}
AUTH_SECRET=${AUTH_SECRET:=}
config_file=""

echo "[INFO]: Starting Docker OpenVPN Client..."

# Either a specific file name or a pattern.
if [[ -d "/config" ]]; then
    if [[ $CONFIG_FILE ]]; then
        echo "[INFO]: CONFIG_FILE is set to: $CONFIG_FILE"
        config_file=$(find /config -name "$CONFIG_FILE" 2> /dev/null | sort | shuf -n 1)
    else
        echo "[INFO]: CONFIG_FILE not set, searching for .conf or .ovpn files"
        config_file=$(find /config -name '*.conf' -o -name '*.ovpn' 2> /dev/null | sort | shuf -n 1)
    fi
else
    echo "[ERROR]: /config directory does not exist"
fi

if [[ -z $config_file ]]; then
    echo "[ERROR]: No openvpn configuration file found" >&2
    exit 1
fi

echo "[INFO]: Using openvpn configuration file: $config_file"

openvpn_args=(
    "--config" "$config_file"
    "--cd" "/config"
)

if is_enabled "$KILL_SWITCH"; then
    openvpn_args+=("--route-up" "/usr/local/bin/killswitch.sh $ALLOWED_SUBNETS")
fi

# Docker secret that contains the credentials for accessing the VPN.
if [[ $AUTH_SECRET ]] && [ ! -f "$AUTH_SECRET" ]; then
    echo "[ERROR]: AUTH_SECRET file not found" >&2
    exit 1
fi

if [[ $AUTH_SECRET ]]; then
    openvpn_args+=("--auth-user-pass" "$AUTH_SECRET")
fi

openvpn "${openvpn_args[@]}" &
openvpn_pid=$!

trap cleanup TERM

wait $openvpn_pid
