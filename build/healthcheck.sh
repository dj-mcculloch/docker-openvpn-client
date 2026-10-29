#!/bin/bash
#
# VPN Health Check
# Healthy when the killswitch is in place and traffic goes out through the
# tunnel. OpenVPN runs as PID 1, so if it dies the container stops.
#

is_enabled() {
    [[ ${1,,} =~ ^(true|t|yes|y|1|on|enable|enabled)$ ]]
}

if is_enabled "${KILLSWITCH:-on}" && ! iptables -C OUTPUT -m addrtype ! --dst-type LOCAL -j REJECT 2>/dev/null; then
    echo "FAIL: killswitch rule missing"
    exit 1
fi

if ! ip route get 8.8.8.8 2>/dev/null | grep -q "dev tun0"; then
    echo "FAIL: tunnel down (traffic not routed through tun0)"
    exit 1
fi

# curl's own error names the step that failed (the lookup or the connection)
if ! err=$(curl -sS --max-time 8 -o /dev/null http://google.com 2>&1); then
    echo "FAIL: ${err:-curl failed}"
    exit 1
fi

echo "PASS: VPN tunnel up and passing traffic"
