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

    # acme.sh keeps its account key and per-cert renewal state in a "home" dir.
    # The apk-packaged acme.sh has NO default home, so every invocation must
    # pass --home explicitly. We keep it under the bind-mounted config volume
    # so the account and renewal state survive container restarts.
    ACME_HOME=/etc/ocserv/config/acme
    mkdir -p "$ACME_HOME"

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

# 5. Start ocserv in the foreground
echo "Starting ocserv..."
exec ocserv -c /etc/ocserv/config/ocserv.conf -f -d 1
