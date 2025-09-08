#!/usr/bin/env bash
#
# VPN Container Test Suite
# Validation of VPN container functionality
# 
# Tests: Container status, VPN connection, tunnel interface, routing, 
#        killswitch, DNS resolution, and external IP connectivity
#
# Usage: ./test-vpn.sh [container_name]
# Example: ./test-vpn.sh vpn
#

set -o nounset
set -o pipefail

CONTAINER_NAME="${1:-vpn}"
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

# Core functionality tests
echo -n "Container Running: "
TESTS=$((TESTS + 1))
if docker ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
    echo -e "${GREEN}✅ PASS${NC}"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}❌ FAIL${NC}"
fi

echo -n "VPN Connected: "
TESTS=$((TESTS + 1))
# Test multiple indicators of active VPN connection
VPN_PROCESS=$(docker exec "${CONTAINER_NAME}" ps aux 2>/dev/null | grep -c "openvpn.*config" || echo "0")
VPN_ROUTE_CHECK=$(docker exec "${CONTAINER_NAME}" ip route get 8.8.8.8 2>/dev/null | grep -c "dev tun0" || echo "0")
TUN_UP_CHECK=$(docker exec "${CONTAINER_NAME}" ip link show tun0 2>/dev/null | grep -c "UP,LOWER_UP" || echo "0")

if [[ "$VPN_PROCESS" -gt 0 ]] && [[ "$VPN_ROUTE_CHECK" -gt 0 ]] && [[ "$TUN_UP_CHECK" -gt 0 ]]; then
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

echo -n "VPN Routing: "
TESTS=$((TESTS + 1))
if docker exec "${CONTAINER_NAME}" ip route show 2>/dev/null | grep -q "dev tun0"; then
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

echo -n "DNS Resolution: "
TESTS=$((TESTS + 1))
if docker exec "${CONTAINER_NAME}" timeout "${TIMEOUT}" nslookup google.com 2>/dev/null | grep -q "Address:"; then
    echo -e "${GREEN}✅ PASS${NC}"
    PASSED=$((PASSED + 1))
else
    echo -e "${RED}❌ FAIL${NC}"
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

show_summary