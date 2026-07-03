# ==========================================
# Stage 1: Builder
# ==========================================
# Pin the minor Alpine release instead of :latest so builds are reproducible
# and the base layer cannot drift on an unexpected rebuild. Bump deliberately.
FROM alpine:3.22 AS builder

# Set ocserv version to compile
ENV OCSERV_VERSION=1.5.0

# Install build dependencies
RUN apk add --no-cache \
    build-base xz meson ninja gperf \
    gnutls-dev readline-dev libnl3-dev lz4-dev libseccomp-dev \
    linux-pam-dev talloc-dev protobuf-c-dev \
    libev-dev krb5-dev oath-toolkit-dev libmaxminddb-dev \
    curl

# Download, extract, compile and install ocserv
RUN curl -O https://www.infradead.org/ocserv/download/ocserv-${OCSERV_VERSION}.tar.xz \
    && tar -xf ocserv-${OCSERV_VERSION}.tar.xz \
    && cd ocserv-${OCSERV_VERSION} \
    && meson setup build --prefix=/usr --sysconfdir=/etc \
    && meson compile -C build \
    && meson install -C build

# ==========================================
# Stage 2: Final Production Image
# ==========================================
FROM alpine:3.22

# Install runtime dependencies including socat for acme.sh standalone mode
RUN apk add --no-cache \
    gnutls-utils iptables libnl3 readline libseccomp lz4-libs libev \
    protobuf-c oath-toolkit-liboath oath-toolkit libmaxminddb krb5-libs linux-pam talloc \
    curl socat openssl

# Install acme.sh from the official Alpine package.
# This avoids piping a remote installer into a shell (curl|sh), avoids baking a
# placeholder ACME email into the image, and installs to a standard system path
# (/usr/bin/acme.sh, /usr/share/acme.sh) instead of depending on root's HOME.
# The deployer's email is registered at runtime in entrypoint.sh via ACME_EMAIL.
RUN apk add --no-cache acme.sh

# Copy compiled ocserv binaries from builder
COPY --from=builder /usr/sbin/ocserv /usr/sbin/ocserv
COPY --from=builder /usr/sbin/ocserv-worker /usr/sbin/ocserv-worker
COPY --from=builder /usr/bin/ocpasswd /usr/bin/ocpasswd
COPY --from=builder /usr/bin/occtl /usr/bin/occtl

# Prepare directories
RUN mkdir -p /etc/ocserv/certs /etc/ocserv/config

# Inject entrypoint script
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /etc/ocserv
ENTRYPOINT ["entrypoint.sh"]
