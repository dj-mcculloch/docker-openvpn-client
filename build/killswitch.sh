#!/usr/bin/env bash
#
# OpenVPN Killswitch Script
# 
# This script configures iptables firewall rules to block all traffic except:
# - Traffic through VPN tunnel (tun0)
# - Local Docker network traffic  
# - Connections to VPN servers
# - Optional allowed subnets
#
# Usage: killswitch.sh [allowed_subnets] [config_file]
#   allowed_subnets: Comma-separated list of subnets to allow (optional)
#   config_file: OpenVPN config file path for server IP extraction (optional)
#

# Debug logging (controlled by DEBUG environment variable)
if [[ "${DEBUG:-}" == "true" ]]; then
    exec 3>&1
    log() { echo "[$(date)] $*" >&3; }
else
    exec 3>/dev/null
    log() { :; }
fi

log "Starting killswitch configuration"
log "Args: allowed_subnets='$1' config_file='$2'"
log "Environment: DEBUG=${DEBUG:-false}"

set -o errexit
set -o nounset  
set -o pipefail

# =============================================================================
# Helper Functions
# =============================================================================

validate_subnet() {
    local subnet="$1"
    # Basic CIDR format validation (IPv4 only)
    if [[ $subnet =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        # Extract IP and prefix parts
        local ip="${subnet%/*}"
        local prefix="${subnet#*/}"
        
        # Validate IP octets (0-255) and prefix (0-32)
        local IFS='.'
        local -a octets=($ip)
        
        if [[ ${#octets[@]} -eq 4 ]] && [[ $prefix -ge 0 && $prefix -le 32 ]]; then
            for octet in "${octets[@]}"; do
                if [[ $octet -lt 0 || $octet -gt 255 ]]; then
                    return 1
                fi
            done
            return 0
        fi
    fi
    return 1
}

# =============================================================================
# Firewall Configuration - Killswitch Rules
# =============================================================================

configure_firewall() {
    local docker_network
    # Enhanced Docker network detection with multiple fallbacks
    docker_network=$(ip -4 -oneline addr show dev eth0 2>/dev/null | awk 'NR == 1 { print $4 }' || 
                     ip route 2>/dev/null | awk '/docker/ { print $1; exit }' || 
                     ip route 2>/dev/null | awk '/172\./ { print $1; exit }' || 
                     echo "172.17.0.0/16")
    
    log "Docker network detected: $docker_network"
    
    # Store for summary logging
    DOCKER_NETWORK="$docker_network"
    
    # Wait for network stack to be ready by checking basic connectivity
    log "Waiting for network stack to be ready..."
    local stack_ready_count=0
    while [ $stack_ready_count -lt 30 ]; do  # Up to 30 seconds
        # Check if basic network interfaces are operational
        if ip link show eth0 &>/dev/null && ip route show default &>/dev/null; then
            log "Network stack is operational"
            break
        fi
        sleep 1
        ((stack_ready_count++))
    done
    
    # Wait for tun0 interface to be available and operational (up to 30 seconds)
    log "Waiting for tun0 interface..."
    local tun_ready_count=0
    while [ $tun_ready_count -lt 30 ]; do
        if ip link show tun0 &>/dev/null; then
            # Additional check: ensure tun0 has an IP address assigned
            if ip addr show tun0 2>/dev/null | grep -q "inet "; then
                log "tun0 interface is available with IP address"
                break
            else
                log "tun0 interface exists but no IP assigned yet..."
            fi
        fi
        sleep 1
        ((tun_ready_count++))
    done
    
    # Wait for VPN routes to be established with adaptive polling (up to 30 seconds)
    log "Waiting for VPN routes to be established..."
    local route_ready_count=0
    local routes_found=false
    while [ $route_ready_count -lt 30 ] && [ "$routes_found" = false ]; do
        if ip route show | grep -q "via.*dev tun0"; then
            # Verify routes are stable by checking twice with a short interval
            sleep 0.5
            if ip route show | grep -q "via.*dev tun0"; then
                log "VPN routes confirmed and stable in routing table"
                routes_found=true
                break
            else
                log "VPN routes detected but unstable, continuing to wait..."
            fi
        fi
        sleep 1
        ((route_ready_count++))
    done
    
    # Final verification that everything is ready
    if [ "$routes_found" = false ]; then
        log "Warning: VPN routes not found after 30 seconds"
    fi
    
    # Verify tun0 exists before applying rules
    if ! ip link show tun0 &>/dev/null; then
        log "Warning: tun0 interface not found, skipping killswitch rules"
        return 0  # Don't fail the script if tun0 isn't ready yet
    fi
    
    # Clean up any existing killswitch rules to prevent duplicates
    # Remove any existing ACCEPT rules for tun0
    while iptables -D OUTPUT -o tun0 -j ACCEPT 2>/dev/null; do :; done
    # Remove any existing REJECT rules with addrtype match
    while iptables -D OUTPUT ! -o tun0 -m addrtype ! --dst-type LOCAL ! -d "$docker_network" -j REJECT 2>/dev/null; do :; done
    
    # Apply killswitch rules in correct order
    # Rule 1: Allow all traffic through VPN tunnel (highest priority)
    iptables --insert OUTPUT 1 --out-interface tun0 --jump ACCEPT
    
    # Rule 2: Block all traffic NOT going through VPN tunnel  
    # Exceptions: Local traffic and Docker network communication
    iptables --append OUTPUT \
        ! --out-interface tun0 \
        --match addrtype ! --dst-type LOCAL \
        ! --destination "$docker_network" \
        --jump REJECT
}

# =============================================================================
# Additional Subnet Configuration  
# =============================================================================

configure_allowed_subnets() {
    local allowed_subnets="${1:-}"
    [[ -n "$allowed_subnets" ]] || return 0
    
    log "Configuring allowed subnets: $allowed_subnets"
    local default_gateway
    default_gateway=$(ip -4 route | awk '$1 == "default" { print $3 }')
    
    # Add routes and firewall exceptions for each allowed subnet
    for subnet in ${allowed_subnets//,/ }; do
        # Validate subnet format
        if ! validate_subnet "$subnet"; then
            log "WARNING: Invalid subnet format: $subnet (expected format: 192.168.1.0/24)"
            log "Skipping subnet: $subnet"
            continue
        fi
        
        log "Processing allowed subnet: $subnet"
        # Add route - expect exit code 2 if route already exists
        if ! ip route add "$subnet" via "$default_gateway" 2>/dev/null; then
            route_exit_code=$?
            if [[ $route_exit_code -eq 2 ]]; then
                log "Route for $subnet already exists, continuing..."
            else
                log "ERROR: Failed to add route for $subnet (exit code: $route_exit_code)"
                exit $route_exit_code
            fi
        else
            log "Added route for $subnet via $default_gateway"
        fi
        
        # Add iptables rule - iptables allows duplicates, so this should always work
        if ! iptables --insert OUTPUT --destination "$subnet" --jump ACCEPT 2>/dev/null; then
            iptables_exit_code=$?
            log "ERROR: Failed to add iptables rule for $subnet (exit code: $iptables_exit_code)"
            exit $iptables_exit_code
        else
            log "Added iptables rule for $subnet"
        fi
    done
}

# =============================================================================
# Main Execution
# =============================================================================

# Store docker network for summary
DOCKER_NETWORK=""

configure_firewall
configure_allowed_subnets "${1:-}"

log "Firewall configuration completed"
log "Summary:"
log "  - VPN tunnel traffic: ALLOWED via tun0"  
log "  - Docker network traffic: ALLOWED via ${DOCKER_NETWORK:-auto-detected}"
log "  - Additional subnets: ${1:-none configured}"
log "  - All other traffic: BLOCKED (killswitch active)"

# =============================================================================
# VPN Server Access - Allow connections to OpenVPN servers
# =============================================================================

# Process VPN server configuration
config="${2:-}"
if [[ -n "$config" && -f "$config" ]]; then
    # Set defaults (will be overridden by values in remote lines)
    global_port="1194"
    global_protocol="udp"
    remotes=$(awk '$1 == "remote" && NF >= 2 { print $2, ($3 ? $3 : ""), ($4 ? $4 : "") }' "$config" 2>/dev/null)
    
    # Process each remote server entry
    if [[ -n "$remotes" ]]; then
        ip_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            
            # Parse remote server (strip comments)
            IFS=" " read -ra remote <<< "${line%%#*}"
            address=${remote[0]}
            port=${remote[1]:-$global_port}
            protocol=${remote[2]:-$global_protocol}

            # Add firewall rules for VPN server access
            if [[ $address =~ $ip_regex ]]; then
                # Clean up any existing rule for this server first - expect exit code 1 if rule doesn't exist
                if iptables -D OUTPUT -d "$address" -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null; then
                    log "Cleaned up existing rule for $address:$port"
                else
                    cleanup_exit_code=$?
                    if [[ $cleanup_exit_code -eq 1 ]]; then
                        log "No existing rule to clean up for $address:$port, continuing..."
                    else
                        log "ERROR: Failed to clean up rule for $address:$port (exit code: $cleanup_exit_code)"
                        exit $cleanup_exit_code
                    fi
                fi
                
                # Add the new rule
                if ! iptables --insert OUTPUT 2 --destination "$address" --protocol "$protocol" --destination-port "$port" --jump ACCEPT; then
                    add_exit_code=$?
                    log "ERROR: Failed to add rule for $address:$port (exit code: $add_exit_code)"
                    exit $add_exit_code
                else
                    log "Added rule for $address:$port ($protocol)"
                fi
            else
                # Find already-resolved server IPs from routing table
                resolved_ips=$(ip route | awk '/via.*dev eth0/ { print $1 }' | grep -E '^[0-9.]+(/32)?$' | sed 's|/32||' 2>/dev/null)
                if [[ -z "$resolved_ips" ]]; then
                    log "WARNING: No resolved IPs found for hostname $address"
                fi
                
                for ip in $resolved_ips; do
                    [[ -n "$ip" ]] || continue
                    
                    # Clean up any existing rule for this IP first - expect exit code 1 if rule doesn't exist
                    if iptables -D OUTPUT -d "$ip" -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null; then
                        log "Cleaned up existing rule for $ip:$port"
                    else
                        cleanup_exit_code=$?
                        if [[ $cleanup_exit_code -eq 1 ]]; then
                            log "No existing rule to clean up for $ip:$port, continuing..."
                        else
                            log "ERROR: Failed to clean up rule for $ip:$port (exit code: $cleanup_exit_code)"
                            exit $cleanup_exit_code
                        fi
                    fi
                    
                    # Add the new rule
                    if ! iptables --insert OUTPUT 2 --destination "$ip" --protocol "$protocol" --destination-port "$port" --jump ACCEPT; then
                        add_exit_code=$?
                        log "ERROR: Failed to add rule for $ip:$port (exit code: $add_exit_code)"
                        exit $add_exit_code
                    else
                        log "Added rule for $ip:$port ($protocol)"
                    fi
                done
            fi
        done <<< "$remotes"
    fi
fi

log "Killswitch script completed successfully"
exit 0
