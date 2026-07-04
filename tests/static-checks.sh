#!/bin/sh
set -eu

failures=0

require() {
    file=$1
    pattern=$2
    description=$3

    if ! grep -Fq "$pattern" "$file"; then
        echo "FAIL: $description" >&2
        echo "      missing '$pattern' in $file" >&2
        failures=$((failures + 1))
    fi
}

require Dockerfile "OCSERV_SHA256" "ocserv source tarball must be pinned by checksum"
require Dockerfile "sha256sum -c" "ocserv source tarball checksum must be verified during build"

require entrypoint.sh "VPN_IPV4_CIDR" "VPN IPv4 CIDR must be configurable from one place"
require entrypoint.sh 'iptables -t nat -C POSTROUTING -s "$VPN_IPV4_CIDR"' "NAT must use VPN_IPV4_CIDR instead of a hard-coded subnet"
require entrypoint.sh 'chmod 600 /etc/ocserv/config/ocpasswd' "ocpasswd must be owner-readable only"
require entrypoint.sh 'chmod 700 "$ACME_HOME"' "ACME state directory must be private"
require entrypoint.sh 'if [ -n "$SRV_DNS" ]; then' "self-signed DNS SAN must be opt-in"
require entrypoint.sh 'if [ -n "$SRV_IP" ]; then' "self-signed IP SAN must be opt-in"
require entrypoint.sh "VPN_IPV6_MODE" "IPv6 mode must be explicit to avoid silent leak-prone defaults"
require entrypoint.sh "VPN_IPV6_CIDR" "IPv6 VPN CIDR must be configurable when IPv6 is enabled"

require config/ocserv.conf "ipv6-network = fda9:4efe:7e3b:03ea::/64" "IPv6 full-tunnel example must be documented in ocserv config"

require README.md "VPN_IPV4_CIDR" "README must document the shared VPN IPv4 CIDR knob"
require README.md "SRV_DNS" "README must document self-signed DNS SAN configuration"
require README.md "SRV_IP" "README must document self-signed IP SAN configuration"
require README.md "VPN_IPV6_MODE" "README must document IPv6 leak-prevention mode"

require docker-compose.yml "# - SRV_DNS=vpn.example.com" "self-signed DNS SAN must remain commented by default"
require docker-compose.yml "# - SRV_IP=203.0.113.10" "self-signed IP SAN must remain commented by default"

if [ "$failures" -gt 0 ]; then
    exit 1
fi

echo "static checks passed"
