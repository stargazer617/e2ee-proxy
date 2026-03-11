#!/bin/bash
#
# E2EE proxy entrypoint - handles TLS certificate setup and starts OpenResty.
#
# TLS modes (checked in order):
#   1. Custom cert:    TLS_CERT + TLS_KEY env vars point to PEM files
#   2. Self-signed:    TLS_SELF_SIGNED=true generates a cert at startup
#   3. Embedded:       (default) certs loaded from native .so at runtime
#
set -e

TLS_MODE="embedded"

# --- Mode 1: Custom cert files ---
if [ -n "${TLS_CERT:-}" ] && [ -n "${TLS_KEY:-}" ]; then
    TLS_MODE="custom"
    echo "=== TLS mode: custom certificate ==="

    cp "$TLS_CERT" /tmp/ssl.crt
    cp "$TLS_KEY" /tmp/ssl.key
    chmod 600 /tmp/ssl.key

    if [ -n "${TLS_CA:-}" ]; then
        cp "$TLS_CA" /tmp/ssl.ca
        echo "  CA chain: $TLS_CA"
    fi

    echo "  Cert: $TLS_CERT"
    echo "  Key:  $TLS_KEY"

# --- Mode 2: Self-signed cert ---
elif [ "${TLS_SELF_SIGNED:-}" = "true" ]; then
    TLS_MODE="self-signed"
    DOMAIN="${TLS_DOMAIN:-localhost}"
    echo "=== TLS mode: self-signed certificate ==="
    echo "  Domain: $DOMAIN"

    openssl req -x509 -newkey rsa:2048 \
        -keyout /tmp/ssl.key -out /tmp/ssl.crt \
        -days 365 -nodes \
        -subj "/CN=$DOMAIN" \
        -addext "subjectAltName=DNS:$DOMAIN,DNS:localhost,IP:127.0.0.1" \
        2>/dev/null

    chmod 600 /tmp/ssl.key

    echo ""
    echo "  Self-signed certificate generated for: $DOMAIN"
    echo ""
    echo "  To trust this certificate:"
    echo ""
    echo "    # Copy cert out of container:"
    echo "    docker cp \$(docker ps -qf ancestor=e2ee-proxy):/tmp/ssl.crt ./ssl.crt"
    echo ""
    echo "    # macOS:"
    echo "    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ssl.crt"
    echo ""
    echo "    # Linux (Debian/Ubuntu):"
    echo "    sudo cp ssl.crt /usr/local/share/ca-certificates/e2ee-proxy.crt && sudo update-ca-certificates"
    echo ""
    echo "    # Windows (PowerShell as Admin):"
    echo "    Import-Certificate -FilePath ssl.crt -CertStoreLocation Cert:\\LocalMachine\\Root"
    echo ""

# --- Mode 3: Embedded (default) ---
else
    echo "=== TLS mode: embedded (from native .so) ==="
fi

# Generate throwaway dummy cert (OpenResty requires ssl_certificate to point
# at a real file even when ssl_certificate_by_lua_block overrides it)
if [ ! -f /tmp/dummy.crt ]; then
    openssl req -x509 -newkey rsa:2048 -keyout /tmp/dummy.key -out /tmp/dummy.crt \
        -days 1 -nodes -subj "/CN=dummy" 2>/dev/null
fi

# Determine server_name
SERVER_NAME="${TLS_DOMAIN:-_}"

# Extract resolvers from /etc/resolv.conf for nginx
RESOLVERS=$(grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ' ')
if [ -z "$RESOLVERS" ]; then
    RESOLVERS="8.8.8.8 1.1.1.1"
fi
echo "Using DNS resolvers: $RESOLVERS"

CONF=/usr/local/openresty/nginx/conf/nginx.conf
sed -i "s/__RESOLVERS__/$RESOLVERS/" "$CONF"
sed -i "s/__SERVER_NAME__/$SERVER_NAME/g" "$CONF"

exec /usr/local/openresty/bin/openresty -g "daemon off;"
