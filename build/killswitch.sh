#!/usr/bin/env bash
#
# OpenVPN Killswitch
#
# Run once by the entrypoint, before OpenVPN starts. Blocks all outbound
# traffic except:
# - traffic through the tunnel (tun0)
# - the container's Docker network and local addresses (Docker's DNS, ports)
# - ALLOWED_SUBNETS
# - OpenVPN's own traffic to its servers, on the config's ports
#
# The rules don't depend on the tunnel's state, so they hold while OpenVPN
# reconnects. OpenVPN's exception allows any server IP (a provider can move a
# hostname to new IPs at any time), but only for processes in this container's
# own cgroup: containers sharing its network namespace
# (network_mode: service:...) never match it, whatever user they run as.
# Needs cgroup v2 and Linux 6.1+ (or 5.15.75+ / 6.0.3+): older kernels resolve
# the cgroup path from the host's root, so it would match every container.
#
# Usage: killswitch.sh <config_file> [allowed_subnets]
#   allowed_subnets: comma-separated, e.g. 192.168.1.0/24,10.0.0.0/24
#

set -o errexit
set -o nounset
set -o pipefail

config="$1"
allowed_subnets="${2:-}"

docker_network=$(ip -4 -oneline addr show dev eth0 | awk 'NR == 1 { print $4 }')
cgroup=$(awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup)   # this container's cgroup

iptables -A OUTPUT -o tun0 -j ACCEPT
iptables -A OUTPUT -d "$docker_network" -j ACCEPT
for subnet in ${allowed_subnets//,/ }; do
    iptables -A OUTPUT -d "$subnet" -j ACCEPT
done

# One rule per port/protocol OpenVPN will use, resolved as OpenVPN does: a
# <connection> block starts from the config's port/rport/proto set above it
# (later global lines don't reach it) and its own lines apply in order; a
# global remote's own port/protocol overrides the config's (defaults 1194/udp).
awk '
    BEGIN { blk = 0 }
    { sub(/\r$/, ""); sub(/[[:space:]]+[#;].*/, "") }   # CRLF, trailing comments
    $1 == "<connection>"  { blk = ++nblk; port[blk] = port[0]; proto[blk] = proto[0] }
    $1 == "</connection>" { blk = 0 }
    $1 == "port" || $1 == "rport" { port[blk] = $2 }
    $1 == "proto" { proto[blk] = $2 }
    $1 == "remote" && NF >= 2 {
        if (blk) { if ($3) port[blk] = $3; if ($4) proto[blk] = $4 }
        else { n++; rport[n] = $3; rproto[n] = $4 }
    }
    END {
        for (i = 1; i <= n; i++)
            print (rport[i] ? rport[i] : port[0] ? port[0] : 1194), (rproto[i] ? rproto[i] : proto[0] ? proto[0] : "udp")
        for (b = 1; b <= nblk; b++)
            print (port[b] ? port[b] : 1194), (proto[b] ? proto[b] : "udp")
    }' "$config" | sort -u |
while read -r port protocol; do
    protocol=${protocol%-client}   # tcp-client -> tcp
    protocol=${protocol%[46]}      # udp4 -> udp
    iptables -A OUTPUT -p "$protocol" --dport "$port" -m cgroup --path "$cgroup" -j ACCEPT
    echo "Killswitch: OpenVPN may reach any server on $port/$protocol"
done

iptables -A OUTPUT -m addrtype ! --dst-type LOCAL -j REJECT

# IPv6: allow loopback and the tunnel only.
if ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null; then
    ip6tables -A OUTPUT -o tun0 -j ACCEPT
    ip6tables -A OUTPUT -j REJECT
else
    echo "Killswitch: ip6tables unavailable; IPv6 not filtered"
fi

echo "Killswitch active: all traffic outside tun0 blocked except $docker_network${allowed_subnets:+, $allowed_subnets}"
