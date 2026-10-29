#!/usr/bin/env bash
#
# OpenVPN DNS Up/Down Script (--dns-updown)
#
# Docker gives this container, and every container sharing its network
# namespace, one /etc/resolv.conf that points at Docker's resolver
# (127.0.0.11). On Docker Desktop that resolver forwards from the host,
# outside the tunnel, so app lookups leak. OpenVPN's stock script can't fix
# it: its `sed -i` can't replace the bind-mounted file, and it still exits 0.
#
#   dns-up:   replace Docker's resolver with the pushed DNS servers (Docker's
#             nameserver lines are commented out), so everything here, the
#             health check included, resolves through the tunnel
#   dns-down: restore Docker's lines (also run by the entrypoint at start)
#
# Both keep Docker's resolver closed to other containers in this network
# namespace (matched by cgroup, so whatever user they run as). While the
# tunnel is down, OpenVPN, in this container, can still resolve its server's
# hostname; the apps' lookups fail instead of leaking.
#

set -o errexit
set -o nounset
set -o pipefail

[ -z "${dns_vars_file:-}" ] || . "$dns_vars_file"

conf=/etc/resolv.conf
begin="# openvpn-client: VPN DNS begin"
end="# openvpn-client: VPN DNS end"
hidden="#openvpn-client: tunnel up: "

# Docker's own lines, as they were before an earlier dns-up
docker_lines=$(sed -e "/^${begin}\$/,/^${end}\$/d" -e "s/^${hidden}//" "$conf")

cgroup=$(awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup)   # this container's cgroup
rule=(OUTPUT -d 127.0.0.11 -m cgroup ! --path "$cgroup" -j REJECT)
iptables -w -C "${rule[@]}" 2>/dev/null || iptables -w -I "${rule[@]}"

case "${script_type:-}" in
    dns-up)
        # OpenVPN runs this only with at least one server
        servers=()
        for var in $(compgen -v dns_server_ | grep -E '^dns_server_[0-9]+_address_[0-9]+$' | sort -t_ -k3,3n -k5,5n); do
            servers+=("${!var}")
        done
        servers=("${servers[@]:0:3}")   # resolvers read at most 3
        # Write in place (no rename): the file is a bind mount
        {
            echo "$begin"
            printf 'nameserver %s\n' "${servers[@]}"
            echo "$end"
            sed "s/^nameserver/${hidden}&/" <<< "$docker_lines"
        } > "$conf"
        echo "dns-updown: DNS through the tunnel: ${servers[*]}"
        ;;
    dns-down)
        printf '%s\n' "$docker_lines" > "$conf"
        echo "dns-updown: Docker's resolver restored"
        ;;
    *)
        echo "dns-updown: unknown script_type '${script_type:-}'" >&2
        exit 1
        ;;
esac
