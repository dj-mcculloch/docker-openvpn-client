FROM cgr.dev/chainguard/wolfi-base:latest

# Install required packages
RUN apk add --no-cache \
    bash \
    curl \
    iptables \
    openvpn

# Copy scripts with executable permissions
COPY --chmod=755 entrypoint.sh killswitch.sh /usr/local/bin/

# Default environment variables
ENV KILL_SWITCH=on \
    DEBUG=false

# Improved health check - verify VPN is connected and functional
HEALTHCHECK --interval=30s --timeout=10s --start-period=45s --retries=3 \
    CMD pgrep openvpn > /dev/null && \
        (ip route | grep -q tun || ip route | grep -q tap) || exit 1

ENTRYPOINT ["entrypoint.sh"]