#!/bin/sh
set -e

# 1. Fallback for /dev/net/tun
if [ ! -c /dev/net/tun ]; then
    echo "Creating /dev/net/tun..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# 2. Setup iptables NAT forwarding for the VPN subnet
echo "Configuring iptables for NAT..."
iptables -t nat -C POSTROUTING -s 192.168.211.0/24 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 192.168.211.0/24 -j MASQUERADE

# 3. Ensure ocpasswd file exists
if [ ! -f /etc/ocserv/config/ocpasswd ]; then
    echo "Creating empty ocpasswd file..."
    touch /etc/ocserv/config/ocpasswd
fi

# 4. Handle Certificates
mkdir -p /etc/ocserv/certs

if [ -n "$DOMAIN" ]; then
    echo "DOMAIN is set to $DOMAIN. Managing Let's Encrypt certificates via acme.sh..."

    # Register (or update) the ACME account using the deployer's own email.
    # The email is NOT baked into the image; it must be supplied at runtime via
    # the ACME_EMAIL environment variable when DOMAIN is set.
    if [ -z "$ACME_EMAIL" ]; then
        echo "Error: ACME_EMAIL is required when DOMAIN is set (used for Let's Encrypt account registration and expiry notices)." >&2
        exit 1
    fi
    acme.sh --register-account -m "$ACME_EMAIL" 2>/dev/null || acme.sh --update-account -m "$ACME_EMAIL"

    if [ ! -f "/etc/ocserv/certs/server-cert.pem" ]; then
        echo "No certificate found for $DOMAIN. Issuing a new one..."
        # Use standalone mode (requires port 80 to be mapped and free)
        acme.sh --issue -d "$DOMAIN" --standalone
        
        echo "Installing certificate into /etc/ocserv/certs..."
        acme.sh --install-cert -d "$DOMAIN" \
                --cert-file      /etc/ocserv/certs/server-cert.pem  \
                --key-file       /etc/ocserv/certs/server-key.pem  \
                --fullchain-file /etc/ocserv/certs/fullchain.pem \
                --reloadcmd     "occtl reload"
    else
        echo "Certificate for $DOMAIN already exists."
    fi
    
    # Start cron daemon to handle automatic renewals for acme.sh
    crond
else
    echo "No DOMAIN specified. Using or generating self-signed certificates..."
    
    if [ ! -f /etc/ocserv/certs/server-key.pem ] || [ ! -f /etc/ocserv/certs/server-cert.pem ]; then
        echo "Generating self-signed CA and server certificates..."
        
        certtool --generate-privkey --outfile /etc/ocserv/certs/ca-key.pem
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
        certtool --generate-self-signed --load-privkey /etc/ocserv/certs/ca-key.pem \
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
        certtool --generate-certificate --load-privkey /etc/ocserv/certs/server-key.pem \
            --load-ca-certificate /etc/ocserv/certs/ca-cert.pem \
            --load-ca-privkey /etc/ocserv/certs/ca-key.pem \
            --template /tmp/server.tmpl --outfile /etc/ocserv/certs/server-cert.pem
    fi
fi

# 5. Start ocserv in the foreground
echo "Starting ocserv..."
exec ocserv -c /etc/ocserv/config/ocserv.conf -f -d 1
