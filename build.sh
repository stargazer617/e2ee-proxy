#!/bin/bash
#
# Build the e2ee-proxy Docker image.
#
# Usage:
#   # With certs (embedded mode):
#   ./build.sh \
#     --cert /path/to/cert.pem \
#     --intermediate /path/to/intermediate.pem \
#     --root /path/to/root.pem \
#     --key /path/to/privkey.pem \
#     --xvmp /path/to/xvmp
#
#   # Without certs (must use TLS_SELF_SIGNED=true or TLS_CERT/TLS_KEY at runtime):
#   ./build.sh --xvmp /path/to/xvmp
#
# Or with env vars:
#   CERT_PEM=... INT_PEM=... ROOT_PEM=... KEY_PEM=... XVMP_DIR=... ./build.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cert)       CERT_PEM="$2"; shift 2 ;;
        --intermediate|--int) INT_PEM="$2"; shift 2 ;;
        --root)       ROOT_PEM="$2"; shift 2 ;;
        --key)        KEY_PEM="$2"; shift 2 ;;
        --xvmp)       XVMP_DIR="$2"; shift 2 ;;
        --tag)        TAG="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

: "${XVMP_DIR:=$HOME/git/aegis/xvmp}"
: "${TAG:=e2ee-proxy}"

HAS_CERTS=true

# Check if cert args were provided
if [ -z "${CERT_PEM:-}" ] || [ -z "${INT_PEM:-}" ] || [ -z "${ROOT_PEM:-}" ] || [ -z "${KEY_PEM:-}" ]; then
    HAS_CERTS=false
fi

# Verify cert files exist (if provided)
if [ "$HAS_CERTS" = true ]; then
    for f in "$CERT_PEM" "$INT_PEM" "$ROOT_PEM" "$KEY_PEM"; do
        if [ ! -f "$f" ]; then
            echo "ERROR: file not found: $f" >&2
            exit 1
        fi
    done
fi

if [ ! -d "$XVMP_DIR/crypto" ] || [ ! -d "$XVMP_DIR/packer" ]; then
    echo "ERROR: xvmp dir not valid: $XVMP_DIR" >&2
    exit 1
fi

# Create temporary build context with everything Docker needs
BUILD_CTX=$(mktemp -d)
trap "rm -rf $BUILD_CTX" EXIT

echo "=== Preparing build context in $BUILD_CTX ==="

# Copy proxy sources
cp -r "$SCRIPT_DIR/native" "$BUILD_CTX/native"
cp -r "$SCRIPT_DIR/lua" "$BUILD_CTX/lua"
cp -r "$SCRIPT_DIR/conf" "$BUILD_CTX/conf"
cp "$SCRIPT_DIR/entrypoint.sh" "$BUILD_CTX/entrypoint.sh"
cp "$SCRIPT_DIR/Dockerfile" "$BUILD_CTX/Dockerfile"

# Copy xvmp sources (only what we need, not the full tree)
mkdir -p "$BUILD_CTX/xvmp"
cp -r "$XVMP_DIR/crypto" "$BUILD_CTX/xvmp/crypto"
cp -r "$XVMP_DIR/packer" "$BUILD_CTX/xvmp/packer"
cp -r "$XVMP_DIR/passes-modern" "$BUILD_CTX/xvmp/passes-modern"

# Copy certs into build context (or create empty dir)
mkdir -p "$BUILD_CTX/certs"
if [ "$HAS_CERTS" = true ]; then
    cp "$CERT_PEM" "$BUILD_CTX/certs/cert.pem"
    cp "$INT_PEM" "$BUILD_CTX/certs/intermediate.pem"
    cp "$ROOT_PEM" "$BUILD_CTX/certs/root.pem"
    cp "$KEY_PEM" "$BUILD_CTX/certs/privkey.pem"
else
    echo ""
    echo "WARNING: Building without embedded certs."
    echo "  The embedded TLS mode will NOT work at runtime."
    echo "  You must use one of:"
    echo "    -e TLS_SELF_SIGNED=true                     (self-signed cert)"
    echo "    -e TLS_CERT=/path/cert -e TLS_KEY=/path/key (custom cert)"
    echo ""
fi

echo "=== Building Docker image: $TAG ==="

docker build \
    --platform linux/amd64 \
    -t "$TAG" \
    "$BUILD_CTX"

echo ""
echo "=== Build complete: $TAG ==="
echo ""
echo "Run with:"
if [ "$HAS_CERTS" = true ]; then
    echo "  docker run -p 443:443 -p 80:80 $TAG"
else
    echo "  docker run -p 443:443 -p 80:80 -e TLS_SELF_SIGNED=true $TAG"
fi
