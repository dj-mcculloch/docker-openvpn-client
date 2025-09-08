# OpenVPN Client for Docker

[![Build and Push to GHCR](https://github.com/dj-mcculloch/docker-openvpn-client/actions/workflows/build.yaml/badge.svg)](https://github.com/dj-mcculloch/docker-openvpn-client/actions/workflows/build.yaml)

A hardened OpenVPN client container built on Chainguard's Wolfi base image. This is a fork of [WFG's archived `docker-openvpn-client`](https://github.com/wfg/docker-openvpn-client). DISCLAIMER: this project was primarily vibe-coded with Claude Code.

## What is this and what does it do?
[`ghcr.io/dj-mcculloch/openvpn-client`](https://github.com/dj-mcculloch/docker-openvpn-client/pkgs/container/openvpn-client) is a containerized OpenVPN client.
It has a kill switch built with `iptables` that kills Internet connectivity to the container if the VPN tunnel goes down for any reason.

This image requires you to supply the necessary OpenVPN configuration file(s). Because of this, any VPN provider should work.

If you find something that doesn't work or have an idea for a new feature, issues and **pull requests are welcome** (however, I'm not promising they will be merged).

## Enhanced Security Features
This fork includes several security and reliability improvements over the original:

- **Hardened Base Image**: Built on Chainguard's Wolfi base image, which is designed for security with minimal attack surface and no shell access
- **Automatic Network Detection**: Smart detection of Docker network configuration eliminates manual subnet configuration in most cases
- **Enhanced Logging**: Comprehensive debug logging with timestamps for better troubleshooting
- **Improved Connection Verification**: Robust connection establishment verification with configurable timeout and retry logic
- **Graceful Shutdown**: Proper signal handling ensures clean container shutdown with configurable timeout
- **Multi-Architecture Support**: Native support for both AMD64 and ARM64 architectures
- **Comprehensive Testing**: Included test suite validates all aspects of VPN functionality

## Why?
Having a containerized VPN client lets you use container networking to easily choose which applications you want using the VPN instead of having to set up split tunnelling. It also keeps you from having to install an OpenVPN client on the underlying host.

This was forked from [WFG's archived `docker-openvpn-client`](https://github.com/wfg/docker-openvpn-client) because I was having issues with the original project and it was no longer being maintained.

## How do I use it?
### Getting the image
You can either pull it from GitHub Container Registry or build it yourself.

To pull it from GitHub Container Registry, run
```
docker pull ghcr.io/dj-mcculloch/openvpn-client:latest
```

To build it yourself, run
```
docker build -t ghcr.io/dj-mcculloch/openvpn-client https://github.com/dj-mcculloch/docker-openvpn-client.git#:build
```

### Creating and running a container
The image requires the container be created with the `NET_ADMIN` capability and `/dev/net/tun` accessible.
Below are bare-bones examples for `docker run` and Compose; however, you'll probably want to do more than just run the VPN client.
See the below to learn how to have [other containers use `openvpn-client`'s network stack](#using-with-other-containers).

#### `docker run`
```
docker run --detach \
  --name=openvpn-client \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  --volume <path/to/config/dir>:/config \
  ghcr.io/dj-mcculloch/openvpn-client:latest
```

#### `docker-compose`
```yaml
services:
  openvpn-client:
    image: ghcr.io/dj-mcculloch/openvpn-client:latest
    container_name: openvpn-client
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      # ALLOWED_SUBNETS auto-detected from container network interface
      # AUTH_SECRET: /config/credentials.txt  # uncomment if using auth file
      # DEBUG: true  # uncomment for detailed logging
      KILLSWITCH: true
    volumes:
      - <path/to/config/dir>:/config
    restart: unless-stopped
```

#### Environment variables
| Variable | Default (blank is unset) | Description |
| --- | --- | --- |
| `ALLOWED_SUBNETS` | Auto-detected | A list of one or more comma-separated subnets (e.g. `192.168.0.0/24,192.168.1.0/24`) to allow outside of the VPN tunnel. If unset, the container will auto-detect the Docker network from the eth0 interface. |
| `AUTH_SECRET` | | Path to a file containing your VPN credentials (username on first line, password on second line). |
| `CONFIG_FILE` | | The OpenVPN configuration file or search pattern. If unset, a random `.conf` or `.ovpn` file will be selected. |
| `DEBUG` | `false` | Enable debug logging to see detailed container startup and connection information. Set to any "truthy" value[1] to enable. |
| `KILLSWITCH` | `on` | Whether or not to enable the kill switch. Set to any "truthy" value[1] to enable. |

[1] "Truthy" values in this context are the following: `true`, `t`, `yes`, `y`, `1`, `on`, `enable`, or `enabled`.

##### Environment variable considerations
###### `ALLOWED_SUBNETS`
If you intend on connecting to containers that use the OpenVPN container's network stack (which you probably do), the container will automatically detect your Docker network and allow traffic from it.
In most cases, you won't need to set this variable manually. However, if you have a custom network setup or need to allow multiple specific subnets, you can override the auto-detection by setting this variable.
Regardless of whether or not you're using the kill switch, the entrypoint script also adds routes to each of the allowed subnets to enable network connectivity from outside of Docker.

###### `AUTH_SECRET`
This variable should point to a file containing your VPN credentials (username on first line, password on second line).
See the [Compose file](docker-compose.yml) in this repository for an example of mounting a credentials file into the container.

### Using with other containers
Once you have your `openvpn-client` container up and running, you can tell other containers to use `openvpn-client`'s network stack which gives them the ability to utilize the VPN tunnel.
There are a few ways to accomplish this depending on how your container is created.

If your container is being created with
1. the same Compose YAML file as `openvpn-client`, add `network_mode: service:openvpn-client` to the container's service definition.
2. a different Compose YAML file than `openvpn-client`, add `network_mode: container:openvpn-client` to the container's service definition.
3. `docker run`, add `--network=container:openvpn-client` as an option to `docker run`.

Once running and provided your container has `wget` or `curl`, you can run `docker exec <container_name> wget -qO - ifconfig.me` or `docker exec <container_name> curl -s ifconfig.me` to get the public IP of the container and make sure everything is working as expected.
This IP should match the one of `openvpn-client`.

#### Handling ports intended for connected containers
If you have a connected container and you need to access a port on that container, you'll want to publish that port on the `openvpn-client` container instead of the connected container.
To do that, add `-p <host_port>:<container_port>` if you're using `docker run`, or add the below snippet to the `openvpn-client` service definition in your Compose file if using `docker-compose`.
```yaml
ports:
  - <host_port>:<container_port>
```
In both cases, replace `<host_port>` and `<container_port>` with the port used by your connected container.

### Testing your VPN connection
This repository includes a comprehensive test script that validates all aspects of your VPN container functionality.

#### Using the test script
The `test-vpn.sh` script performs 7 different tests to ensure your VPN is working correctly:

1. **Container Running** - Verifies the container is up and running
2. **VPN Connected** - Checks that OpenVPN process is active and tunnel is established
3. **Tunnel Interface** - Validates the TUN interface has an IP address
4. **VPN Routing** - Ensures traffic is routed through the VPN tunnel
5. **Killswitch Active** - Confirms iptables rules are blocking non-VPN traffic
6. **DNS Resolution** - Tests that DNS queries work through the VPN
7. **External IP** - Retrieves your external IP and VPN provider information

To run the test script:
```bash
# Test default container named 'vpn'
./test-vpn.sh

# Test a specific container
./test-vpn.sh openvpn-client
```

The script will output colorized results for each test and provide a summary. A successful run looks like:
```
VPN Container Test Suite
Testing container: openvpn-client

Container Running: ✅ PASS
VPN Connected: ✅ PASS
Tunnel Interface: ✅ PASS
VPN Routing: ✅ PASS
Killswitch Active: ✅ PASS
DNS Resolution: ✅ PASS
External IP: ✅ 203.0.113.45
   Provider: Example VPN Provider
   ASN: AS12345 Example VPN AS
   Location: Amsterdam, Netherlands

Results: 7/7 tests passed
🎉 All tests passed!
```

#### Quick verification (alternative method)
If you prefer a simpler verification or want to test how other containers will behave when using the VPN's network stack, you can run this quick check:

```bash
docker run --rm -it --network=container:openvpn-client alpine wget -qO - ifconfig.me
```

This command spins up a temporary Alpine container that uses `openvpn-client` for networking, which simulates how your other containers will connect through the VPN. The command returns the public IP address that external services see, which should match your VPN provider's IP address.

This method is useful for:
- Quick verification without running the full test suite
- Testing the exact network configuration your other containers will use
- Troubleshooting connectivity issues with containers that use the VPN's network stack

### Troubleshooting
#### VPN authentication
Your OpenVPN configuration file may not come with authentication baked in.
To provide OpenVPN the necessary credentials, create a file (any name will work, but this example will use `credentials.txt`) next to the OpenVPN configuration file with your username on the first line and your password on the second line.

For example:
```
vpn_username
vpn_password
```

In the OpenVPN configuration file, add the following line:
```
auth-user-pass credentials.txt
```

This will tell OpenVPN to read `credentials.txt` whenever it needs credentials.
