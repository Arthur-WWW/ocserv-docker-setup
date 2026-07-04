#!/bin/sh
set -e

default_vpn_ipv4_cidr() {
    awk -F= '
        /^[[:space:]]*ipv4-network[[:space:]]*=/ {
            value = $2
            gsub(/[[:space:]]/, "", value)
            if (value ~ /\//) {
                print value
                exit
            }
        }
    ' /etc/ocserv/config/ocserv.conf 2>/dev/null
}

VPN_IPV4_CIDR=${VPN_IPV4_CIDR:-$(default_vpn_ipv4_cidr)}
VPN_IPV4_CIDR=${VPN_IPV4_CIDR:-192.168.211.0/24}
VPN_IPV6_MODE=${VPN_IPV6_MODE:-off}
VPN_IPV6_CIDR=${VPN_IPV6_CIDR:-fda9:4efe:7e3b:03ea::/64}

# 1. Fallback for /dev/net/tun
if [ ! -c /dev/net/tun ]; then
    echo "Creating /dev/net/tun..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# 2. Setup iptables NAT forwarding for the VPN subnet
echo "Configuring IPv4 iptables NAT for $VPN_IPV4_CIDR..."
iptables -t nat -C POSTROUTING -s "$VPN_IPV4_CIDR" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "$VPN_IPV4_CIDR" -j MASQUERADE

case "$VPN_IPV6_MODE" in
    off|disabled|false|0)
        echo "VPN IPv6 mode is off. If clients keep a public IPv6 route, disable IPv6 on the client or enable VPN_IPV6_MODE=nat with matching ocserv IPv6 config."
        ;;
    nat)
        echo "Configuring IPv6 ip6tables NAT for $VPN_IPV6_CIDR..."
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || echo "Warning: could not enable IPv6 forwarding inside the container."
        ip6tables -t nat -C POSTROUTING -s "$VPN_IPV6_CIDR" -j MASQUERADE 2>/dev/null || ip6tables -t nat -A POSTROUTING -s "$VPN_IPV6_CIDR" -j MASQUERADE
        ;;
    *)
        echo "Error: VPN_IPV6_MODE must be 'off' or 'nat'." >&2
        exit 1
        ;;
esac

# 3. Ensure ocpasswd file exists
if [ ! -f /etc/ocserv/config/ocpasswd ]; then
    echo "Creating empty ocpasswd file..."
    touch /etc/ocserv/config/ocpasswd
fi
chmod 600 /etc/ocserv/config/ocpasswd

# 4. Handle Certificates
mkdir -p /etc/ocserv/certs
chmod 700 /etc/ocserv/certs

if [ -n "$DOMAIN" ]; then
    echo "DOMAIN is set to $DOMAIN. Managing Let's Encrypt certificates via acme.sh..."

    # acme.sh keeps its account key and per-cert renewal state in a "home" dir.
    # The apk-packaged acme.sh has NO default home, so every invocation must
    # pass --home explicitly. We keep it under the bind-mounted config volume
    # so the account and renewal state survive container restarts.
    ACME_HOME=/etc/ocserv/config/acme
    mkdir -p "$ACME_HOME"
    chmod 700 "$ACME_HOME"

    # Register (or update) the ACME account using the deployer's own email.
    # The email is NOT baked into the image; it must be supplied at runtime via
    # the ACME_EMAIL environment variable when DOMAIN is set.
    if [ -z "$ACME_EMAIL" ]; then
        echo "Error: ACME_EMAIL is required when DOMAIN is set (used for Let's Encrypt account registration and expiry notices)." >&2
        exit 1
    fi
    acme.sh --register-account -m "$ACME_EMAIL" --home "$ACME_HOME" --server letsencrypt 2>/dev/null \
        || acme.sh --update-account -m "$ACME_EMAIL" --home "$ACME_HOME" --server letsencrypt

    if [ ! -f "/etc/ocserv/certs/server-cert.pem" ]; then
        echo "No certificate found for $DOMAIN. Issuing a new one..."
        # Use standalone mode (requires port 80 to be mapped and free)
        acme.sh --issue -d "$DOMAIN" --standalone --home "$ACME_HOME" --server letsencrypt

        echo "Installing certificate into /etc/ocserv/certs..."
        # No --reloadcmd: ocserv periodically checks the cert files and reloads
        # them automatically on change, so renewal takes effect without a
        # restart. On first run ocserv is not started yet anyway, so a reload
        # command would fail and just noise the logs.
        acme.sh --install-cert -d "$DOMAIN" \
                --cert-file      /etc/ocserv/certs/server-cert.pem  \
                --key-file       /etc/ocserv/certs/server-key.pem  \
                --fullchain-file /etc/ocserv/certs/fullchain.pem \
                --home "$ACME_HOME" --server letsencrypt
        chmod 600 /etc/ocserv/certs/server-key.pem
    else
        echo "Certificate for $DOMAIN already exists."
    fi

    # Register the renewal cron job. --home MUST be passed here too: acme.sh
    # bakes the --home value into the cron entry it writes, and the renewal
    # will silently no-op if it points at a directory with no account/cert
    # state. Verified that --install-cronjob propagates --home correctly.
    acme.sh --install-cronjob --home "$ACME_HOME"
    # Start cron daemon to handle automatic renewals for acme.sh.
    crond
else
    echo "No DOMAIN specified. Using or generating self-signed certificates..."
    
    if [ ! -f /etc/ocserv/certs/server-key.pem ] || [ ! -f /etc/ocserv/certs/server-cert.pem ]; then
        echo "Generating self-signed CA and server certificates..."

        # The CA private key is only needed to sign the server cert; ocserv
        # never uses it at runtime. Generate it in /tmp and delete it right
        # after signing, so the root trust key is NOT persisted onto the
        # bind-mounted certs/ volume (host backups, other containers, etc).
        certtool --generate-privkey --outfile /tmp/ca-key.pem
        chmod 600 /tmp/ca-key.pem
        cat <<EOF > /tmp/ca.tmpl
cn = "${CA_CN:-VPN CA}"
organization = "${CA_ORG:-Private Network}"
serial = 1
expiration_days = 3650
ca
signing_key
cert_signing_key
crl_signing_key
EOF
        certtool --generate-self-signed --load-privkey /tmp/ca-key.pem \
            --template /tmp/ca.tmpl --outfile /etc/ocserv/certs/ca-cert.pem

        certtool --generate-privkey --outfile /etc/ocserv/certs/server-key.pem
        cat <<EOF > /tmp/server.tmpl
cn = "${SRV_CN:-vpn.example.com}"
organization = "${SRV_ORG:-Private Network}"
serial = 2
expiration_days = 3650
tls_www_server
encryption_key
signing_key
EOF
        if [ -n "$SRV_DNS" ]; then
            echo "dns_name = \"${SRV_DNS}\"" >> /tmp/server.tmpl
        fi
        if [ -n "$SRV_IP" ]; then
            echo "ip_address = \"${SRV_IP}\"" >> /tmp/server.tmpl
        fi
        certtool --generate-certificate --load-privkey /etc/ocserv/certs/server-key.pem \
            --load-ca-certificate /etc/ocserv/certs/ca-cert.pem \
            --load-ca-privkey /tmp/ca-key.pem \
            --template /tmp/server.tmpl --outfile /etc/ocserv/certs/server-cert.pem

        # Private key used only to sign the server cert; destroy it now.
        rm -f /tmp/ca-key.pem
        # Restrict the persisted private key to the owner (certtool's default
        # perms are too open for a key on a host-mounted volume).
        chmod 600 /etc/ocserv/certs/server-key.pem
    fi
fi

if [ -f /etc/ocserv/certs/server-key.pem ]; then
    chmod 600 /etc/ocserv/certs/server-key.pem
fi

# 5. Start ocserv in the foreground
echo "Starting ocserv..."
exec ocserv -c /etc/ocserv/config/ocserv.conf -f -d 1
