#!/usr/bin/env bash
# generate-self-signed.sh — generate a self-signed TLS cert for local development.
# Output: ./certs/dev/selfsigned.{crt,key}
set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")/.." && pwd)/certs/dev"
mkdir -p "$CERT_DIR"

echo "Generating self-signed certificate in $CERT_DIR ..."

openssl req -x509 \
    -newkey rsa:4096 \
    -keyout "$CERT_DIR/selfsigned.key" \
    -out    "$CERT_DIR/selfsigned.crt" \
    -sha256 \
    -days   365 \
    -nodes \
    -subj "/C=US/ST=Dev/L=Dev/O=uye-edge-dev/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

echo "Done."
echo "  Certificate : $CERT_DIR/selfsigned.crt"
echo "  Private key : $CERT_DIR/selfsigned.key"
