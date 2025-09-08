#!/usr/bin/env bash
#
# OpenVPN Container Entrypoint
# Configures and starts OpenVPN with killswitch functionality
#

set -o errexit
set -o nounset
set -o pipefail

echo "OpenVPN Container starting..."

# =============================================================================
# Signal handling and cleanup
# =============================================================================

cleanup() {
    log "Received shutdown signal, cleaning up..."
    
    if [[ ${openvpn_pid:-} ]]; then
        log "Terminating OpenVPN process (PID: $openvpn_pid)"
        kill -TERM "$openvpn_pid" 2>/dev/null || true
        
        # Wait for graceful shutdown
        local timeout=10
        while [[ $timeout -gt 0 ]] && kill -0 "$openvpn_pid" 2>/dev/null; do
            debug "Waiting for OpenVPN to terminate... ($timeout seconds remaining)"
            sleep 1
            ((timeout--))
        done
        
        # Force kill if still running
        if kill -0 "$openvpn_pid" 2>/dev/null; then
            log "Force killing OpenVPN process"
            kill -KILL "$openvpn_pid" 2>/dev/null || true
        fi
        
        log "OpenVPN shutdown complete"
    fi
    
    exit 0
}

# Handle multiple signals
trap cleanup TERM INT QUIT

# =============================================================================
# Helper functions
# =============================================================================

is_enabled() {
    [[ ${1,,} =~ ^(true|t|yes|y|1|on|enable|enabled)$ ]]
}

debug() {
    if is_enabled "${DEBUG:-false}"; then
        echo "[DEBUG] $*" >&2
    fi
}

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# =============================================================================
# Environment configuration
# =============================================================================

CONFIG_FILE=${CONFIG_FILE:=}
KILL_SWITCH=${KILL_SWITCH:=on}
ALLOWED_SUBNETS=${ALLOWED_SUBNETS:=}
AUTH_SECRET=${AUTH_SECRET:=}
DEBUG=${DEBUG:=false}

debug "Environment variables:"
debug "  CONFIG_FILE='$CONFIG_FILE'"
debug "  KILL_SWITCH='$KILL_SWITCH'"
debug "  ALLOWED_SUBNETS='$ALLOWED_SUBNETS'"
debug "  AUTH_SECRET='$AUTH_SECRET'"
debug "  DEBUG='$DEBUG'"

# =============================================================================
# Configuration file discovery
# =============================================================================

# Validate /config directory exists
if [[ ! -d /config ]]; then
    log "ERROR: /config directory not found or not mounted" >&2
    exit 1
fi

if [[ $CONFIG_FILE ]]; then
    debug "Searching for specified config file: $CONFIG_FILE"
    config_file=$(find /config -name "$CONFIG_FILE" 2>/dev/null | head -1)
    if [[ -z $config_file ]]; then
        log "ERROR: Specified config file '$CONFIG_FILE' not found in /config" >&2
        exit 1
    fi
    log "Using specified config file: $config_file"
else
    log "Auto-discovering OpenVPN config files in /config..."
    config_file=$(find /config -name '*.conf' -o -name '*.ovpn' 2>/dev/null | head -1)
    if [[ -z $config_file ]]; then
        log "ERROR: No OpenVPN configuration file (.conf/.ovpn) found in /config" >&2
        debug "Available files in /config:"
        debug "$(find /config -type f 2>/dev/null | head -10)"
        exit 1
    fi
    log "Auto-discovered config: $config_file"
fi

# Validate config file is readable
if [[ ! -r $config_file ]]; then
    log "ERROR: Configuration file is not readable: $config_file" >&2
    exit 1
fi

debug "Config file validation passed"

# =============================================================================
# OpenVPN configuration
# =============================================================================

openvpn_args=(
    "--config" "$config_file"
    "--cd" "/config"
    "--script-security" "2"
    "--route-delay" "5"
    "--verb" "4"
)

# Configure killswitch
if is_enabled "$KILL_SWITCH"; then
    echo "Killswitch enabled"
    openvpn_args+=("--route-up" "/usr/local/bin/killswitch.sh \"${ALLOWED_SUBNETS:-}\" \"$config_file\"")
else
    echo "Killswitch disabled"
fi

# Configure authentication
if [[ $AUTH_SECRET ]]; then
    if [[ ! -f "$AUTH_SECRET" ]]; then
        echo "ERROR: AUTH_SECRET file not found: $AUTH_SECRET" >&2
        exit 1
    fi
    echo "Using authentication file: $AUTH_SECRET"
    openvpn_args+=("--auth-user-pass" "$AUTH_SECRET")
fi

# =============================================================================
# Connection health verification
# =============================================================================

verify_connection() {
    local max_attempts=30
    local attempt=1
    
    log "Verifying VPN connection establishment..."
    
    while [[ $attempt -le $max_attempts ]]; do
        if pgrep -f openvpn > /dev/null; then
            if ip route | grep -q tun || ip route | grep -q tap; then
                log "VPN connection established successfully"
                debug "VPN routes: $(ip route | grep -E '(tun|tap)')"
                return 0
            fi
        fi
        
        debug "Connection attempt $attempt/$max_attempts - waiting for VPN tunnel..."
        sleep 2
        ((attempt++))
    done
    
    log "ERROR: VPN connection failed to establish within $((max_attempts * 2)) seconds" >&2
    return 1
}

# =============================================================================
# Start OpenVPN
# =============================================================================

log "Starting OpenVPN..."
debug "OpenVPN arguments: ${openvpn_args[*]}"

openvpn "${openvpn_args[@]}" &
openvpn_pid=$!

log "OpenVPN started with PID: $openvpn_pid"

# Verify connection in background to avoid blocking
(
    sleep 5  # Give OpenVPN time to start
    if ! verify_connection; then
        log "Connection verification failed, killing OpenVPN process"
        kill -TERM "$openvpn_pid" 2>/dev/null || true
        exit 1
    fi
) &

wait $openvpn_pid
