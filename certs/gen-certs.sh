#!/bin/sh
# Generates a single ECDSA P-256 self-signed cert shared by both nginx
# variants (PQC and classic), so the only thing that differs between the
# two benchmark targets is the TLS key-exchange group, not the signature
# algorithm or key size.
set -eu

OUT_DIR="${1:-/out}"

if [ -f "$OUT_DIR/server.key" ] && [ -f "$OUT_DIR/server.crt" ]; then
  echo "certs already exist in $OUT_DIR, skipping"
  exit 0
fi

openssl ecparam -name prime256v1 -genkey -noout -out "$OUT_DIR/server.key"
openssl req -new -x509 -key "$OUT_DIR/server.key" -out "$OUT_DIR/server.crt" \
  -days 365 -subj "/CN=localhost"

chmod 644 "$OUT_DIR/server.key" "$OUT_DIR/server.crt"
echo "wrote $OUT_DIR/server.key and $OUT_DIR/server.crt"
