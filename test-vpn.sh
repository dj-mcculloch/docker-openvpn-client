#!/usr/bin/env bash
#
# VPN Container Test Suite
# Validation of VPN container functionality
# 
# Tests: Container status, VPN connection, tunnel interface, routing,
#        killswitch, DNS resolution, DNS leak protection, and external IP
#        connectivity; then prints the external IP of every running container
#
# Usage: ./test-vpn.sh <container_name>
# Example: ./test-vpn.sh openvpn-client
#

set -o nounset
set -o pipefail

# Require container name as parameter
if [ $# -eq 0 ]; then
    echo "Error: Container name is required"
    echo "Usage: $0 <container_name>"
    echo "Example: $0 openvpn-client"
    exit 1
fi

CONTAINER_NAME="$1"
TIMEOUT=10

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test tracking
TESTS=0
PASSED=0

# Helper function

show_summary() {
    echo
    echo -e "${BLUE}Results: ${PASSED}/${TESTS} tests passed${NC}"
    if [ $PASSED -eq $TESTS ]; then
        echo -e "${GREEN}🎉 All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}❌ Some tests failed${NC}"
        exit 1
    fi
}

# Test Suite
echo -e "${BLUE}VPN Container Test Suite${NC}"
echo -e "${BLUE}Testing container: ${CONTAINER_NAME}${NC}"
echo

# Check if container is running first
if ! docker ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "${RED}❌ Container '${CONTAINER_NAME}' is not running${NC}"
    exit 1
fi

# Check container health status before running tests
echo -n "Container Health Status: "
HEALTH_STATUS=$(docker inspect "${CONTAINER_NAME}" --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}')

case "$HEALTH_STATUS" in
    "healthy")
        echo -e "${GREEN}✅ Healthy${NC}"
        ;;
    "unhealthy")
        echo -e "${RED}❌ Unhealthy - VPN may not be properly established${NC}"
        echo "Container is unhealthy. Please wait for it to become healthy before running tests."
        echo "You can monitor health with: docker inspect ${CONTAINER_NAME} --format='{{.State.Health.Status}}'"
        exit 1
        ;;
    "starting")
        echo -e "${BLUE}⏳ Starting - Health check in progress${NC}"
        echo "Container is still starting up. Please wait a few minutes for health check to complete."
        echo "You can monitor progress with: docker logs ${CONTAINER_NAME}"
        exit 1
        ;;
    "no-healthcheck")
        echo -e "${BLUE}ℹ️  No health check configured${NC}"
        echo "Warning: This container doesn't have a health check. Tests may fail if VPN isn't ready."
        ;;
    *)
        echo -e "${RED}❌ Unknown health status: ${HEALTH_STATUS}${NC}"
        exit 1
        ;;
esac

echo

# Core functionality tests
echo -n "VPN Connected: "
TESTS=$((TESTS + 1))
# OpenVPN runs, traffic routes through tun0, and tun0 is up
if docker exec "${CONTAINER_NAME}" pgrep -x openvpn >/dev/null 2>&1 &&
   docker exec "${CONTAINER_NAME}" ip route get 8.8.8.8 2>/dev/null | grep -q "dev tun0" &&
   docker exec "${CONTAINER_NAME}" ip link show tun0 2>/dev/null | grep -q "UP,LOWER_UP"; then
    echo -e "${GREEN}✅ PASS${NC}"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}❌ FAIL${NC}"
fi

echo -n "Tunnel Interface: "
TESTS=$((TESTS + 1))
if docker exec "${CONTAINER_NAME}" ip addr show tun0 2>/dev/null | grep -q "inet "; then
    echo -e "${GREEN}✅ PASS${NC}"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}❌ FAIL${NC}"
fi

echo -n "Killswitch Active: "
TESTS=$((TESTS + 1))
if docker exec "${CONTAINER_NAME}" iptables -L OUTPUT -v 2>/dev/null | grep -q "tun0"; then
    echo -e "${GREEN}✅ PASS${NC}"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}❌ FAIL${NC}"
fi

# The DNS checks run in throwaway containers sharing the VPN's network, as
# the apps do: the VPN container itself may still use Docker's resolver.
IMAGE=$(docker inspect "${CONTAINER_NAME}" --format '{{.Config.Image}}')

echo -n "DNS Resolution: "
TESTS=$((TESTS + 1))
if DNS_ERR=$(docker run --rm --network "container:${CONTAINER_NAME}" --entrypoint curl "$IMAGE" \
    -sS --max-time 8 -o /dev/null http://google.com 2>&1); then
    echo -e "${GREEN}✅ PASS${NC}"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}❌ FAIL${NC} (${DNS_ERR})"
fi

# A container sharing the VPN's network must not reach Docker's resolver,
# which answers outside the tunnel. Sends one raw DNS query to 127.0.0.11, as
# root; an answer starts with the query ID 1234.
echo -n "DNS Leak Protection: "
TESTS=$((TESTS + 1))
ANSWER=$(docker run --rm --network "container:${CONTAINER_NAME}" --entrypoint bash "$IMAGE" -c \
    'exec 3<>/dev/udp/127.0.0.11/53 || exit
     printf "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01" >&3
     timeout 3 head -c 2 <&3 | od -An -tx1' 2>/dev/null | tr -d ' ')
PROBE_RC=$?
if [[ $PROBE_RC -ne 0 ]]; then
    echo -e "${RED}❌ FAIL${NC} (probe container did not run: exit ${PROBE_RC})"
elif [[ "$ANSWER" == "1234" ]]; then
    echo -e "${RED}❌ FAIL${NC} (Docker's resolver answered a container sharing the VPN's network)"
else
    echo -e "${GREEN}✅ PASS${NC}"
    PASSED=$((PASSED + 1))
fi

# External connectivity test with VPN provider information
echo -n "External IP: "
TESTS=$((TESTS + 1))

# Get detailed IP information including ASN and provider
IP_INFO=$(docker exec "${CONTAINER_NAME}" timeout "${TIMEOUT}" curl -s "http://ip-api.com/json" 2>/dev/null || echo "")

if [[ -n "$IP_INFO" ]] && echo "$IP_INFO" | grep -q '"status":"success"'; then
    # Parse the JSON response for detailed info
    EXTERNAL_IP=$(echo "$IP_INFO" | grep -o '"query":"[^"]*"' | cut -d'"' -f4)
    VPN_ORG=$(echo "$IP_INFO" | grep -o '"org":"[^"]*"' | cut -d'"' -f4)
    VPN_ASN=$(echo "$IP_INFO" | grep -o '"as":"[^"]*"' | cut -d'"' -f4)
    VPN_CITY=$(echo "$IP_INFO" | grep -o '"city":"[^"]*"' | cut -d'"' -f4)
    VPN_COUNTRY=$(echo "$IP_INFO" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
    
    echo -e "${GREEN}✅ ${EXTERNAL_IP}${NC}"
    echo "   Provider: ${VPN_ORG}"
    echo "   ASN: ${VPN_ASN}"
    echo "   Location: ${VPN_CITY}, ${VPN_COUNTRY}"
    PASSED=$((PASSED + 1))
else
    # Fallback to basic IP check if detailed API fails
    BASIC_IP=$(docker exec "${CONTAINER_NAME}" timeout "${TIMEOUT}" curl -s http://httpbin.org/ip 2>/dev/null | grep -o '"[0-9.]*"' | tr -d '"' || echo "")
    if [[ -n "$BASIC_IP" ]]; then
        echo -e "${GREEN}✅ ${BASIC_IP}${NC} (basic check)"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}❌ TIMEOUT${NC} (connectivity issue)"
    fi
fi

# External IP overview for all containers
echo
echo -e "${BLUE}External IP Overview${NC}"
echo "Checking external IP addresses of all running containers (as seen by external services):"
echo

docker ps --format "{{.Names}}" | while IFS= read -r container; do
    if [ -n "$container" ]; then
        printf "%-20s " "$container:"
        ip=$(docker exec "$container" curl -s --connect-timeout 5 ipinfo.io/ip 2>/dev/null || echo "")
        if [ -n "$ip" ] && echo "$ip" | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' > /dev/null; then
            echo -e "${GREEN}$ip${NC}"
        else
            echo -e "${RED}No IP / curl unavailable${NC}"
        fi
    fi
done

show_summary