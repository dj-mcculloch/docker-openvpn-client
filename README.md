# OpenVPN Client for Docker

[![Build and Push to GHCR](https://github.com/dj-mcculloch/docker-openvpn-client/actions/workflows/build.yaml/badge.svg)](https://github.com/dj-mcculloch/docker-openvpn-client/actions/workflows/build.yaml)

A hardened OpenVPN client container built on Chainguard's Wolfi base image. Fork of [WFG's archived `docker-openvpn-client`](https://github.com/wfg/docker-openvpn-client).

## What is this and what does it do?
[`ghcr.io/dj-mcculloch/openvpn-client`](https://github.com/users/dj-mcculloch/packages/container/package/openvpn-client) is a containerized OpenVPN client with an `iptables`-based kill switch that cuts container internet connectivity if the VPN tunnel goes down.

A containerized VPN client lets you use container networking to choose which applications use the VPN instead of setting up split tunnelling, and avoids installing an OpenVPN client on the host.

You supply the OpenVPN configuration file(s), so any VPN provider should work. Issues and PRs are welcome.

## Security Features
This fork includes several security and reliability improvements over the original:

- **Hardened Base Image**: Built on Chainguard's Wolfi base image, designed for security with minimal attack surface and no shell access
- **Automatic Network Detection**: Detection of Docker network configuration eliminates manual subnet configuration in most cases
- **Enhanced Logging**: Debug logging with timestamps for better troubleshooting
- **Improved Connection Verification**: Connection establishment verification with configurable timeout and retry logic
- **Graceful Shutdown**: Proper signal handling ensures clean container shutdown with configurable timeout
- **Multi-Architecture Support**: Native support for both AMD64 and ARM64 architectures
- **Comprehensive Testing**: Included test suite validates all aspects of VPN functionality
- **Advanced Health Checks**: Health monitoring ensures traffic is actually routing through VPN before other services start

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
```
docker run --detach \
  --name=openvpn-client \
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
| `AUTH_SECRET` | | Docker secret containing VPN credentials. |
| `CONFIG_FILE` | | OpenVPN configuration file or search pattern. If unset, a random `.conf` or `.ovpn` file is selected. |
| `KILLSWITCH` | `on` | Whether to enable the kill switch. Set to any "truthy" value[1] to enable. |

[1] "Truthy" values: `true`, `t`, `yes`, `y`, `1`, `on`, `enable`, `enabled`.

##### `ALLOWED_SUBNETS`
If you connect to containers using the OpenVPN container's network stack (which you probably do), **you'll want to set this**. The entrypoint adds routes to each subnet to allow network connectivity from outside Docker.

##### `AUTH_SECRET`
Compose supports [Docker secrets](https://docs.docker.com/engine/swarm/secrets/#use-secrets-in-compose). See the [Compose file](docker-compose.yml) for example usage.

#### Health check
The container's health check verifies the OpenVPN process is running, the tunnel interface has an IP, traffic routes through the tunnel, external connectivity works, and (if enabled) the killswitch is active. Other services can wait for this with `depends_on` + `condition: service_healthy` so they never start with unprotected traffic:

```yaml
services:
  openvpn-client:
    # ... as above
  sonarr:
    image: ghcr.io/linuxserver/sonarr
    network_mode: service:openvpn-client
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
