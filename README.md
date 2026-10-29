# OpenVPN Client for Docker

[![Build and Push to GHCR](https://github.com/dj-mcculloch/docker-openvpn-client/actions/workflows/build.yaml/badge.svg)](https://github.com/dj-mcculloch/docker-openvpn-client/actions/workflows/build.yaml)

A hardened OpenVPN client container built on Chainguard's Wolfi base image. Fork of [WFG's archived `docker-openvpn-client`](https://github.com/wfg/docker-openvpn-client).

## What is this and what does it do?
[`ghcr.io/dj-mcculloch/openvpn-client`](https://github.com/users/dj-mcculloch/packages/container/package/openvpn-client) is a containerized OpenVPN client with an `iptables`-based kill switch that cuts container internet connectivity if the VPN tunnel goes down.

A containerized VPN client lets you use container networking to choose which applications use the VPN instead of setting up split tunnelling, and avoids installing an OpenVPN client on the host.

You supply the OpenVPN configuration file(s), so any VPN provider should work. Issues and PRs are welcome.

## Security Features
This fork includes several security and reliability improvements over the original:

- **Hardened Base Image**: Built on Chainguard's Wolfi base image, with only `bash`, `curl`, `iptables` and `openvpn` added
- **Automated Patch Updates**: Image is rebuilt on the 1st and 15th of each month to pull the latest Wolfi base patches under the same version tag, so consumers get current CVE fixes without bumping versions
- **Kill Switch From the First Packet**: Firewall rules are in place before OpenVPN starts and hold through reconnects
- **Survives Server IP Changes**: Reconnects when the provider moves a server hostname to new IPs (see [How it works](#how-it-works))
- **DNS Through the Tunnel**: Containers sharing the VPN's network use the VPN's DNS servers; their lookups fail rather than leak while the tunnel is down
- **Automatic Network Detection**: The container's Docker network stays reachable without configuration
- **Multi-Architecture Support**: Native support for both AMD64 and ARM64 architectures
- **Test Script**: `test-vpn.sh` checks the tunnel, kill switch, DNS and leak protection of a running container
- **Health Checks**: Health monitoring ensures traffic is actually routing through VPN before other services start

## How do I use it?
### Getting the image
Pull from GHCR:
```
docker pull ghcr.io/dj-mcculloch/openvpn-client
```

Or build it yourself:
```
docker build -t ghcr.io/dj-mcculloch/openvpn-client https://github.com/dj-mcculloch/docker-openvpn-client.git#:build
```

### Creating and running a container
The container needs the `NET_ADMIN` capability and access to `/dev/net/tun`. See [Using with other containers](#using-with-other-containers) for how to route other containers through the VPN.

#### `docker run`
The container must be on a user-defined network (see [Requirements](#how-it-works)); Compose creates one for you.
```
docker network create openvpn
docker run --detach \
  --name=openvpn-client \
  --network=openvpn \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  --volume <path/to/config/dir>:/config \
  ghcr.io/dj-mcculloch/openvpn-client
```

#### `docker-compose`
```yaml
services:
  openvpn-client:
    image: ghcr.io/dj-mcculloch/openvpn-client
    container_name: openvpn-client
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    volumes:
      - <path/to/config/dir>:/config
    restart: unless-stopped
```

#### Environment variables
| Variable | Default (blank is unset) | Description |
| --- | --- | --- |
| `ALLOWED_SUBNETS` | | Comma-separated subnets (e.g. `192.168.0.0/24,192.168.1.0/24`) to allow outside of the VPN tunnel. |
| `AUTH_SECRET` | | Path to a file with the VPN username (line 1) and password (line 2), e.g. `/config/credentials.txt` as in the [Compose file](docker-compose.yml), or a Compose secret under `/run/secrets/`. |
| `CONFIG_FILE` | | OpenVPN configuration file or search pattern. If unset, the first `.conf` or `.ovpn` file found is used. |
| `KILLSWITCH` | `on` | Whether to enable the kill switch. Set to any "truthy" value[1] to enable. |
| `VPN_DNS` | `on` | Whether lookups from this container and the containers sharing its network go to the VPN's DNS servers. Set to any "truthy" value[1] to enable. |
| `DEBUG` | `false` | Set to any "truthy" value[1] for verbose OpenVPN logs (`--verb 4`). |

[1] "Truthy" values: `true`, `t`, `yes`, `y`, `1`, `on`, `enable`, `enabled`.

##### `ALLOWED_SUBNETS`
If you connect to containers using the OpenVPN container's network stack (which you probably do), **you'll want to set this**. The entrypoint adds routes to each subnet to allow network connectivity from outside Docker, and the kill switch lets traffic to them through. Every container sharing the network reaches these subnets outside the tunnel, so keep them narrow: a DNS server in them would answer those containers outside the tunnel.

#### Health check
The container's health check verifies the kill switch (if enabled) is in place, traffic routes through the tunnel, and a request to `google.com` succeeds. A failing check prints curl's own error, which names the step that failed (the lookup or the connection). Other services can wait for this with `depends_on` + `condition: service_healthy` so they never start with unprotected traffic:

```yaml
services:
  openvpn-client:
    # ... as above
  sonarr:
    image: ghcr.io/linuxserver/sonarr
    network_mode: service:openvpn-client
    cap_drop:
      - NET_RAW   # see "Kill switch" under How it works
    depends_on:
      openvpn-client:
        condition: service_healthy
```

### Using with other containers
Once `openvpn-client` is running, other containers can use its network stack:

1. Same Compose file as `openvpn-client`: add `network_mode: service:openvpn-client` to the service.
2. Different Compose file: add `network_mode: container:openvpn-client`.
3. `docker run`: add `--network=container:openvpn-client`.

To verify, run a container with `wget` or `curl` and check its public IP — it should match `openvpn-client`'s:
```
docker run --rm -it --network=container:openvpn-client alpine wget -qO - ifconfig.me
```

#### Handling ports for connected containers
Publish ports on the `openvpn-client` container, not the connected container. With `docker run`, add `-p <host_port>:<container_port>`; with Compose, add a `ports:` block to the `openvpn-client` service.

### How it works
- **Kill switch.** Before OpenVPN starts, `iptables` rules block all outbound traffic except through `tun0`, to the container's Docker network, to `ALLOWED_SUBNETS`, and OpenVPN's own traffic to its servers. IPv6 is limited to loopback and `tun0`. The rules don't depend on the tunnel's state, so nothing leaks while OpenVPN reconnects. `iptables` can't see packet sockets, which Docker allows by default (`CAP_NET_RAW`): give containers that share the network `cap_drop: [NET_RAW]`.
- **Server IP changes.** Providers move server hostnames to new IPs. OpenVPN may reach any IP on the ports in the config's `remote` lines, but only from this container's own cgroup, so containers sharing its network can't use that exception whatever user they run as. `persist-tun` is removed from the config at startup: it kept the tunnel's routes up across reconnects, which sent a new server IP into the dead tunnel ("Recursive routing detected").
- **DNS.** Docker gives this container and every container sharing its network one `/etc/resolv.conf`, pointing at Docker's resolver (`127.0.0.11`), which on Docker Desktop answers from the host, outside the tunnel. While the tunnel is up, the VPN's pushed DNS servers replace it, so every lookup, the health check's included, goes through the tunnel. While the tunnel is down, Docker's resolver is back but open only to this container: OpenVPN can look up its server, and other containers' lookups fail instead of leaking. Other containers sharing the network can no longer resolve Docker container names; use `localhost` or IP addresses. If your VPN pushes no DNS servers, add `dns server 1 address <ip>` to the config, or the other containers can't resolve anything.
- **Requirements.**
  - cgroup v2 on Linux 6.1+ (or 5.15.75+ / 6.0.3+). Older kernels resolve the cgroup path from the host's root, so the cgroup match covers every container and the protections above silently fail open; `test-vpn.sh`'s DNS Leak Protection check fails there.
  - A user-defined Docker network (Compose creates one). On the default bridge, `/etc/resolv.conf` lists the host's DNS servers, so the kill switch blocks OpenVPN's lookup of its server, and allowing that server would let other containers' lookups bypass the tunnel.
  - If OpenVPN can't resolve its server on a user-defined network, your Docker host may forward DNS from inside the container's network: use IP addresses in the `remote` lines, or add that DNS server to `ALLOWED_SUBNETS` (other containers sharing the network could then query it directly, outside the tunnel).

### Troubleshooting
#### VPN authentication
If your OpenVPN config doesn't have credentials baked in, create a `credentials.txt` next to the config with username on line 1 and password on line 2:
```
vpn_username
vpn_password
```

Then add to the OpenVPN config:
```
auth-user-pass credentials.txt
```
