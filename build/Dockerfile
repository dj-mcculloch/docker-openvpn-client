FROM cgr.dev/chainguard/wolfi-base:latest

# Install required packages
RUN apk add --no-cache \
    bash \
    curl \
    iptables \
    openvpn

# Copy scripts with executable permissions
COPY --chmod=755 entrypoint.sh killswitch.sh healthcheck.sh /usr/local/bin/

# Default environment variables
ENV KILLSWITCH=on \
    DEBUG=false

# Verify VPN tunnel is routing traffic properly
HEALTHCHECK --interval=30s --timeout=15s --start-period=60s --retries=4 \
    CMD healthcheck.sh

ENTRYPOINT ["entrypoint.sh"]