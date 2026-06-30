# ==========================================
# Stage 1: Builder
# ==========================================
FROM alpine:latest AS builder

# Set ocserv version to compile
ENV OCSERV_VERSION=1.5.0

# Install build dependencies
RUN apk add --no-cache \
    build-base xz \
    gnutls-dev readline-dev libnl3-dev lz4-dev libseccomp-dev \
    linux-pam-dev talloc-dev protobuf-c-dev \
    curl

# Download, extract, compile and install ocserv
RUN curl -O https://www.infradead.org/ocserv/download/ocserv-${OCSERV_VERSION}.tar.xz \
    && tar -xf ocserv-${OCSERV_VERSION}.tar.xz \
    && cd ocserv-${OCSERV_VERSION} \
    && ./configure --prefix=/usr --sysconfdir=/etc \
    && make -j$(nproc) \
    && make install

# ==========================================
# Stage 2: Final Production Image
# ==========================================
FROM alpine:latest

# Install runtime dependencies including socat for acme.sh standalone mode
RUN apk add --no-cache \
    gnutls-utils iptables libnl3 readline libseccomp lz4-libs libev \
    protobuf-c oath-toolkit-libqps oath-toolkit libmaxminddb krb5-libs pam talloc \
    curl socat openssl

# Install acme.sh
RUN curl https://get.acme.sh | sh -s email=my@example.com \
    && ln -s /root/.acme.sh/acme.sh /usr/local/bin/acme.sh

# Copy compiled ocserv binaries from builder
COPY --from=builder /usr/sbin/ocserv /usr/sbin/ocserv
COPY --from=builder /usr/bin/ocpasswd /usr/bin/ocpasswd
COPY --from=builder /usr/bin/occtl /usr/bin/occtl

# Prepare directories
RUN mkdir -p /etc/ocserv/certs /etc/ocserv/config

# Inject entrypoint script
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /etc/ocserv
ENTRYPOINT ["entrypoint.sh"]
