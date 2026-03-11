# =============================================================================
# E2EE Local Proxy - Multi-stage Docker Build
#
# Do NOT call `docker build` directly - use build.sh which prepares
# the build context with the required sources and cert files.
#
# Usage:
#   ./build.sh \
#     --cert /path/to/cert.pem \
#     --intermediate /path/to/intermediate.pem \
#     --root /path/to/root.pem \
#     --key /path/to/privkey.pem \
#     --xvmp /path/to/xvmp
#
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: Build LLVM Passes
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ubuntu:22.04 AS xvmp-passes

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake ninja-build g++ git ca-certificates \
    lsb-release wget software-properties-common gnupg \
    && rm -rf /var/lib/apt/lists/*

RUN wget -qO- https://apt.llvm.org/llvm.sh | bash -s -- 17 all

ENV CC=clang-17
ENV CXX=clang++-17

COPY xvmp/passes-modern/ /xvmp/passes-modern/

RUN mkdir -p /xvmp/build && cd /xvmp/build \
    && cmake -G Ninja ../passes-modern \
       -DCMAKE_BUILD_TYPE=Release \
       -DLLVM_DIR=/usr/lib/llvm-17/lib/cmake/llvm \
    && ninja -j$(nproc) \
    && cp libxVMPPasses.so /opt/libxVMPPasses.so

# ---------------------------------------------------------------------------
# Stage 2: Build native .so with embedded certs
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 ubuntu:22.04 AS native-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    lsb-release wget software-properties-common gnupg \
    libssl-dev zlib1g-dev openssl xxd binutils \
    && rm -rf /var/lib/apt/lists/*

RUN wget -qO- https://apt.llvm.org/llvm.sh | bash -s -- 17 all

ENV PATH="/usr/lib/llvm-17/bin:$PATH"
ENV PASSES=/opt/libxVMPPasses.so

COPY --from=xvmp-passes /opt/libxVMPPasses.so /opt/libxVMPPasses.so

# Copy crypto and packer sources
COPY xvmp/crypto/ /xvmp/crypto/
COPY xvmp/packer/ /xvmp/packer/

# Copy proxy native sources
COPY native/ /build/native/

# Copy certs (prepared by build.sh - these stay in this stage only)
COPY certs/ /tmp/certs/

ENV XVMP_DIR=/xvmp
ENV CERT_PEM=/tmp/certs/cert.pem
ENV INT_PEM=/tmp/certs/intermediate.pem
ENV ROOT_PEM=/tmp/certs/root.pem
ENV KEY_PEM=/tmp/certs/privkey.pem
ENV OUT_DIR=/out
ENV CLANG=clang-17
ENV OPT=opt-17

RUN mkdir -p /out && cd /build/native && bash build_protected.sh

# Purge all cert/key material from this stage
RUN rm -rf /tmp/certs /build/native/embedded_certs.h

# ---------------------------------------------------------------------------
# Stage 3: Runtime
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 openresty/openresty:1.25.3.2-0-jammy

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
RUN opm get ledgetech/lua-resty-http

# Native .so
COPY --from=native-builder /out/libe2ee_proxy.so /usr/local/openresty/lib/libe2ee_proxy.so

# Lua modules
COPY lua/ /usr/local/openresty/lua/

# nginx config
COPY conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

# Entrypoint (generates dummy cert for OpenResty bootstrap)
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 443 80

# Verify .so links correctly
RUN ldconfig && ldd /usr/local/openresty/lib/libe2ee_proxy.so || true

CMD ["/entrypoint.sh"]
