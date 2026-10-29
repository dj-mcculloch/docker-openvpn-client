#!/usr/bin/env bash
#
# OpenVPN Container Entrypoint
# Sets up routes, the killswitch and DNS, then runs OpenVPN in the foreground.
#

set -o errexit
set -o nounset
set -o pipefail

echo "OpenVPN Container starting..."

# =============================================================================
# Helper functions
# =============================================================================

is_enabled() {
    [[ ${1,,} =~ ^(true|t|yes|y|1|on|enable|enabled)$ ]]
}

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# =============================================================================
# Environment configuration
# =============================================================================

CONFIG_FILE=${CONFIG_FILE:-}
KILLSWITCH=${KILLSWITCH:-on}
ALLOWED_SUBNETS=${ALLOWED_SUBNETS:-}
AUTH_SECRET=${AUTH_SECRET:-}
VPN_DNS=${VPN_DNS:-on}
DEBUG=${DEBUG:-false}

# =============================================================================
# Configuration file discovery
# =============================================================================

if [[ ! -d /config ]]; then
    log "ERROR: /config directory not found or not mounted" >&2
    exit 1
fi

if [[ $CONFIG_FILE ]]; then
    config_file=$(find /config -name "$CONFIG_FILE" -print -quit 2>/dev/null)
    if [[ -z $config_file ]]; then
        log "ERROR: Specified config file '$CONFIG_FILE' not found in /config" >&2
        exit 1
    fi
    log "Using specified config file: $config_file"
else
    config_file=$(find /config \( -name '*.conf' -o -name '*.ovpn' \) -print -quit 2>/dev/null)
    if [[ -z $config_file ]]; then
        log "ERROR: No OpenVPN configuration file (.conf/.ovpn) found in /config" >&2
        exit 1
    fi
    log "Auto-discovered config: $config_file"
fi

if [[ ! -r $config_file ]]; then
    log "ERROR: Configuration file is not readable: $config_file" >&2
    exit 1
fi

# persist-tun keeps the tunnel and its routes up across reconnects. When the
# server's hostname then resolves to a new IP, that IP routes into the dead
# tunnel ("Recursive routing detected") and the client never reconnects. Run a
# copy of the config without it; the killswitch still blocks traffic while the
# tunnel is down.
runtime_config=/tmp/openvpn.conf
grep -v -E '^[[:space:]]*persist-tun([[:space:]]|$)' "$config_file" > "$runtime_config"

# =============================================================================
# Network setup, before OpenVPN starts so nothing leaks while it connects
# =============================================================================

# The VPN's redirect-gateway sends everything into the tunnel; route
# ALLOWED_SUBNETS around it through Docker's gateway.
gateway=$(ip -4 route | awk '$1 == "default" { print $3; exit }')
for subnet in ${ALLOWED_SUBNETS//,/ }; do
    ip route replace "$subnet" via "$gateway"
done

if is_enabled "$KILLSWITCH"; then
    /usr/local/bin/killswitch.sh "$runtime_config" "$ALLOWED_SUBNETS"
else
    log "Killswitch disabled"
fi

openvpn_args=(
    --config "$runtime_config"
    --cd /config
    --script-security 2
    --verb "$(is_enabled "$DEBUG" && echo 4 || echo 3)"
)

if is_enabled "$VPN_DNS"; then
    # Close Docker's resolver to the other containers in this network before
    # OpenVPN starts, and restore resolv.conf if a previous run changed it
    script_type=dns-down /usr/local/bin/dns-updown.sh
    openvpn_args+=(--dns-updown /usr/local/bin/dns-updown.sh)
else
    log "VPN DNS disabled: lookups use Docker's resolver, outside the tunnel"
    openvpn_args+=(--dns-updown disable)
fi

if [[ $AUTH_SECRET ]]; then
    if [[ ! -f $AUTH_SECRET ]]; then
        log "ERROR: AUTH_SECRET file not found: $AUTH_SECRET" >&2
        exit 1
    fi
    openvpn_args+=(--auth-user-pass "$AUTH_SECRET")
fi

# =============================================================================
# Start OpenVPN (as PID 1: it handles SIGTERM itself, and if it exits the
# container exits, so Docker's restart policy applies)
# =============================================================================

log "Starting OpenVPN: openvpn ${openvpn_args[*]}"
exec openvpn "${openvpn_args[@]}"
