# E2EE Local Proxy

An OpenResty-based reverse proxy that provides **end-to-end encryption** for the Chutes AI API. It transparently intercepts OpenAI-compatible requests, encrypts them with post-quantum cryptography (ML-KEM-768 + ChaCha20-Poly1305), and forwards them to GPU instances — only the model instance can decrypt the payload.

## Architecture

```
Client (OpenAI SDK / Anthropic SDK)
    │
    ▼  HTTPS (TLS)
┌──────────────┐
│  E2EE Proxy  │  ← You are here
│  (OpenResty) │
└──────┬───────┘
       │  HTTPS + E2EE envelope
       ▼
  api.chutes.ai
       │
       ▼
  GPU Instance (decrypts with instance private key)
```

The proxy runs locally (or in your infrastructure) and speaks the standard OpenAI API, the Claude Messages API, and the OpenAI Responses API. Clients point at `https://e2ee-local-proxy.chutes.dev:8443` instead of `api.chutes.ai`. The proxy handles format translation, key exchange, encryption, nonce management, and streaming decryption transparently.

## Quick Start

```bash
docker run -p 8443:443 parachutes/e2ee-proxy:latest
```

The embedded TLS certificate is valid for `e2ee-local-proxy.chutes.dev`, which resolves to `127.0.0.1`. Use this hostname to avoid certificate errors:

```python
# OpenAI SDK
from openai import OpenAI
client = OpenAI(
    api_key="cpk_...",
    base_url="https://e2ee-local-proxy.chutes.dev:8443/v1",
)
resp = client.chat.completions.create(
    model="deepseek-ai/DeepSeek-V3.1-TEE",
    messages=[{"role": "user", "content": "Hello!"}],
)

# Anthropic SDK
import anthropic
client = anthropic.Anthropic(
    api_key="cpk_...",
    base_url="https://e2ee-local-proxy.chutes.dev:8443",
)
resp = client.messages.create(
    model="deepseek-ai/DeepSeek-V3.1-TEE",
    max_tokens=128,
    messages=[{"role": "user", "content": "Hello!"}],
)

# OpenAI Responses API
client = OpenAI(
    api_key="cpk_...",
    base_url="https://e2ee-local-proxy.chutes.dev:8443/v1",
)
resp = client.responses.create(
    model="deepseek-ai/DeepSeek-V3.1-TEE",
    input="Hello!",
)
```

## Why the TLS Cert Is Protected

The default deployment embeds a TLS certificate and private key directly inside a **protected shared library** (`libe2ee_proxy.so`). This is necessary because:

1. **Certificate Transparency (CT) monitors** like CertSpotter continuously scan for newly-issued certificates and cross-reference them against public key material found in container images, GitHub repos, and package registries.
2. If the private key is stored as a plaintext file (even temporarily during a Docker build), automated scanners **will detect it, flag it, and the CA will revoke the certificate** — often within hours.
3. By embedding the cert material into a compiled and obfuscated shared library, the key material is not recognizable to scanners.

## TLS Modes

The proxy supports three TLS certificate modes, selected via environment variables at container startup.

### 1. Embedded (Default)

Certs are loaded at runtime from the protected `.so`. No files on disk. This is the production mode.

```bash
docker run -p 8443:443 parachutes/e2ee-proxy:latest
```

### 2. Self-Signed (Local Development)

Generates a certificate at startup. Useful for local development and testing.

```bash
docker run -p 8443:443 \
  -e TLS_SELF_SIGNED=true \
  -e TLS_DOMAIN=myproxy.local \
  parachutes/e2ee-proxy:latest
```

The container prints instructions for trusting the cert. To extract it:

```bash
docker cp $(docker ps -qf ancestor=parachutes/e2ee-proxy):/tmp/ssl.crt ./ssl.crt

# macOS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ssl.crt

# Linux (Debian/Ubuntu)
sudo cp ssl.crt /usr/local/share/ca-certificates/e2ee-proxy.crt
sudo update-ca-certificates

# Windows (PowerShell as Admin)
Import-Certificate -FilePath ssl.crt -CertStoreLocation Cert:\LocalMachine\Root
```

`TLS_DOMAIN` defaults to `localhost` if not set.

### 3. Custom Certificate

Bring your own cert and key files via volume mounts.

```bash
docker run -p 8443:443 \
  -v /path/to/cert.pem:/certs/cert.pem:ro \
  -v /path/to/key.pem:/certs/key.pem:ro \
  -v /path/to/ca.pem:/certs/ca.pem:ro \
  -e TLS_CERT=/certs/cert.pem \
  -e TLS_KEY=/certs/key.pem \
  -e TLS_CA=/certs/ca.pem \
  -e TLS_DOMAIN=mydomain.com \
  parachutes/e2ee-proxy:latest
```

`TLS_CA` is optional — if provided, it's appended to the cert chain.

### Environment Variable Reference

| Variable | Description | Default |
|----------|-------------|---------|
| `TLS_CERT` | Path to PEM certificate file | *(none)* |
| `TLS_KEY` | Path to PEM private key file | *(none)* |
| `TLS_CA` | Path to PEM CA chain file (optional) | *(none)* |
| `TLS_SELF_SIGNED` | Set to `true` to generate a self-signed cert | `false` |
| `TLS_DOMAIN` | Domain for server_name and self-signed cert SAN | `localhost` (self-signed) / `_` (catch-all) |
| `ALLOW_NON_CONFIDENTIAL` | Set to `true` to allow non-TEE models | `false` |

### Mode Priority

If multiple variables are set, the first match wins:

1. `TLS_CERT` + `TLS_KEY` → custom mode
2. `TLS_SELF_SIGNED=true` → self-signed mode
3. Neither → embedded mode

## Confidential Compute Requirement

By default, the proxy **rejects requests to models not running in a Trusted Execution Environment (TEE)**. E2EE only guarantees privacy when the GPU instance runs inside confidential compute — otherwise an operator could theoretically dump memory and read decrypted payloads.

Models with `confidential_compute: true` in `/v1/models` (typically suffixed with `-TEE`) are allowed. Non-confidential models return an error:

```
model 'Qwen/Qwen3-32B' is not running in confidential compute (TEE).
E2EE requires confidential compute to guarantee privacy.
Set ALLOW_NON_CONFIDENTIAL=true to override.
```

To bypass this check (e.g. for testing):

```bash
docker run -p 8443:443 -e ALLOW_NON_CONFIDENTIAL=true parachutes/e2ee-proxy:latest
```

## API Endpoints

The proxy exposes multiple API formats — requests to `/v1/messages` and `/v1/responses` are translated to chat completions before encryption:

| Endpoint | Behavior |
|----------|----------|
| `GET /health` | Returns `{"status":"ok"}` |
| `GET /v1/models` | Passthrough to `llm.chutes.ai` (no E2EE) |
| `POST /v1/chat/completions` | E2EE encrypted |
| `POST /v1/messages` | E2EE encrypted (Claude Messages API format, translated to chat completions) |
| `POST /v1/responses` | E2EE encrypted (OpenAI Responses API format, translated to chat completions) |
| `POST /v1/completions` | E2EE encrypted |
| `POST /v1/*` | E2EE encrypted (any v1 path) |
| `OPTIONS *` | CORS preflight (204) |

All other paths return 404.

## E2EE Protocol

For each request, the proxy:

1. **Resolves** the model name to a chute ID via `/v1/models`
2. **Fetches** an available GPU instance and single-use nonce from `api.chutes.ai`
3. **Generates** an ephemeral ML-KEM-768 keypair
4. **Encapsulates** a shared secret using the instance's public key
5. **Derives** symmetric keys via HKDF-SHA256
6. **Compresses** the request body with gzip
7. **Encrypts** with ChaCha20-Poly1305
8. **Sends** the encrypted blob to `api.chutes.ai/e2e/invoke`
9. **Decrypts** the response (or streaming SSE chunks) and returns plaintext to the client

| Primitive | Purpose |
|-----------|---------|
| ML-KEM-768 | Post-quantum key encapsulation (NIST standardized) |
| HKDF-SHA256 | Key derivation from shared secret |
| ChaCha20-Poly1305 | Authenticated encryption (AEAD) |
| Gzip | Payload compression before encryption |

Every request uses a fresh ephemeral keypair — forward secrecy is guaranteed.
