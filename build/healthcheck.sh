#!/bin/bash
#
# Comprehensive VPN Health Check
# Ensures VPN tunnel is established and routing traffic properly
#

# Exit immediately on any failure
set -e

# Check 1: OpenVPN process is running
if ! pgrep -f "openvpn.*config" > /dev/null 2>&1; then
    echo "FAIL: OpenVPN process not running"
    exit 1
fi

# Check 2: Tunnel interface exists and has IP address
if ! ip addr show tun0 | grep -q "inet " 2>/dev/null; then
    echo "FAIL: Tunnel interface tun0 not ready or no IP assigned"
    exit 1
fi

# Check 3: Default route goes through tunnel (critical for protection)
if ! ip route get 8.8.8.8 | grep -q "dev tun" 2>/dev/null; then
    echo "FAIL: Traffic not routing through VPN tunnel"
    exit 1
fi

# Check 4: DNS resolution and external connectivity (if DNS works, connectivity works)
if ! timeout 10 curl -s --max-time 8 http://google.com > /dev/null 2>&1; then
    echo "FAIL: DNS resolution and external connectivity not working"
    exit 1
fi

# Check 5: Verify killswitch is active (if enabled)
if [ "${KILLSWITCH:-on}" = "on" ] || [ "${KILLSWITCH}" = "true" ]; then
    # Check for killswitch rules: look for ACCEPT to tun0 and REJECT for non-VPN traffic
    if ! iptables -L OUTPUT -v | grep -q "tun0" 2>/dev/null; then
        echo "FAIL: Killswitch not active - no tun0 rules found"
        exit 1
    fi
    if ! iptables -L OUTPUT | grep -q "REJECT" 2>/dev/null; then
        echo "FAIL: Killswitch not active - no REJECT rule found"
        exit 1
    fi
fi

# All checks passed
echo "PASS: VPN tunnel fully established and protecting traffic"
exit 0