#!/bin/bash
#
# Build the e2ee proxy shared library.
#
# Expected environment:
#   XVMP_DIR     - path to xvmp source tree
#   PASSES       - path to libxVMPPasses.so
#   CERT_PEM     - path to leaf cert PEM
#   INT_PEM      - path to intermediate cert PEM
#   ROOT_PEM     - path to root cert PEM
#   KEY_PEM      - path to private key PEM
#   OUT_DIR      - output directory (default: /out)
#

set -euo pipefail

: "${XVMP_DIR:?XVMP_DIR not set}"
: "${PASSES:?PASSES not set}"
: "${CERT_PEM:?CERT_PEM not set}"
: "${INT_PEM:?INT_PEM not set}"
: "${ROOT_PEM:?ROOT_PEM not set}"
: "${KEY_PEM:?KEY_PEM not set}"
: "${OUT_DIR:=/out}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IR_DIR="/tmp/ir"
CRYPTO_DIR="${XVMP_DIR}/crypto"
MLKEM_DIR="${CRYPTO_DIR}/mlkem"

CLANG="${CLANG:-clang}"
OPT="${OPT:-opt}"

CFLAGS="-O2 -fPIC -Wall -Wno-unused-parameter -Wno-unused-function \
  -fno-vectorize -fno-slp-vectorize"

mkdir -p "$IR_DIR" "$OUT_DIR"

echo "=== Step 1: Generate embedded certs header ==="
cd "$SCRIPT_DIR"
bash gen_embedded_certs.sh "$CERT_PEM" "$INT_PEM" "$ROOT_PEM" "$KEY_PEM"

echo "=== Step 2: Compile native crypto objects ==="

$CLANG $CFLAGS -I"$CRYPTO_DIR" \
  -c -o "$IR_DIR/secure_crypto.o" "$CRYPTO_DIR/secure_crypto.c"

for f in kem indcpa poly polyvec ntt cbd reduce verify fips202 symmetric-shake randombytes; do
    $CLANG $CFLAGS -DKYBER_K=3 -I"$MLKEM_DIR" \
      -c -o "$IR_DIR/mlkem_${f}.o" "$MLKEM_DIR/${f}.c"
done

echo "=== Step 3: Compile proxy API to LLVM IR ==="
$CLANG -O0 -fPIC \
  -Xclang -disable-O0-optnone \
  -I"$SCRIPT_DIR" -I"$CRYPTO_DIR" -I"$MLKEM_DIR" \
  -DKYBER_K=3 \
  -S -emit-llvm \
  -o "$IR_DIR/e2ee_proxy_api.ll" \
  "$SCRIPT_DIR/e2ee_proxy_api.c"

echo "=== Step 4: reg2mem ==="
$OPT -S -passes=reg2mem \
  -o "$IR_DIR/e2ee_proxy_api_r2m.ll" \
  "$IR_DIR/e2ee_proxy_api.ll"

echo "=== Step 5: Protection pass ==="
$OPT -S -load-pass-plugin="$PASSES" \
  -passes="strvirt,function(iat,autocff,regionvirt,vmp)" \
  -xvmp-autocff=true \
  -xvmp-mba-depth=3 \
  -xvmp-antiemu=true \
  -xvmp-pathexp=true \
  -xvmp-collatz=true \
  -xvmp-mixed-dispatch=true \
  -xvmp-handler-cff=true \
  -xvmp-section-integrity=true \
  -xvmp-callgraph-obf=true \
  -o "$IR_DIR/e2ee_proxy_api_vmp.ll" \
  "$IR_DIR/e2ee_proxy_api_r2m.ll"

echo "=== Step 6: Compile IR to object ==="
$CLANG -c -O2 -fPIC \
  -o "$IR_DIR/e2ee_proxy_api.o" \
  "$IR_DIR/e2ee_proxy_api_vmp.ll"

echo "=== Step 7: Link into .so ==="
$CLANG -shared \
  -Wl,--version-script="$SCRIPT_DIR/exports.map" \
  -o "$OUT_DIR/libe2ee_proxy.so" \
  "$IR_DIR/e2ee_proxy_api.o" \
  "$IR_DIR/secure_crypto.o" \
  "$IR_DIR"/mlkem_*.o \
  -lz -lpthread

echo "=== Step 8: Strip symbols ==="
strip --strip-unneeded "$OUT_DIR/libe2ee_proxy.so"

echo "=== Step 9: Pack .so (optional) ==="
if [ "${SKIP_PACK:-0}" = "1" ]; then
    echo "Skipping packer (SKIP_PACK=1)"
else
    $CLANG -O2 -o /tmp/xvmp-pack-so "$XVMP_DIR/packer/xvmp_pack_so.c" -lz -lcrypto 2>/dev/null

    if /tmp/xvmp-pack-so \
      "$OUT_DIR/libe2ee_proxy.so" \
      -o "$OUT_DIR/libe2ee_proxy_packed.so" \
      --exports "$SCRIPT_DIR/packer_exports.txt" \
      --rodata-guard \
      -v 2>&1; then

        if file "$OUT_DIR/libe2ee_proxy_packed.so" | grep -q "ELF"; then
            mv "$OUT_DIR/libe2ee_proxy_packed.so" "$OUT_DIR/libe2ee_proxy.so"
            echo "Packing succeeded"
        else
            echo "WARNING: packed .so is not valid ELF, using unpacked version"
            rm -f "$OUT_DIR/libe2ee_proxy_packed.so"
        fi
    else
        echo "WARNING: packer failed, using unpacked .so"
        rm -f "$OUT_DIR/libe2ee_proxy_packed.so"
    fi
fi

echo "=== Build complete ==="
ls -la "$OUT_DIR/libe2ee_proxy.so"

rm -f "$SCRIPT_DIR/embedded_certs.h"
