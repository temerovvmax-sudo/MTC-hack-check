#!/bin/bash
# Self-signed lab CA and a certificate for the Gateway hostnames.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${ROOT}/.secrets/tls"
mkdir -p "${DIR}"
chmod 700 "${ROOT}/.secrets" "${DIR}"
if [[ -f "${DIR}/ca.crt" && -f "${DIR}/tls.crt" && -f "${DIR}/tls.key" ]]; then
  echo "tls material already present in ${DIR}"
  exit 0
fi
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout "${DIR}/ca.key" -out "${DIR}/ca.crt" \
  -subj "/CN=TestY Lab CA"
openssl req -newkey rsa:2048 -nodes \
  -keyout "${DIR}/tls.key" -out "${DIR}/tls.csr" \
  -subj "/CN=testy.local"
cat > "${DIR}/san.cnf" <<'EOF'
subjectAltName=DNS:testy.local,DNS:api.testy.local
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
EOF
openssl x509 -req -in "${DIR}/tls.csr" -CA "${DIR}/ca.crt" -CAkey "${DIR}/ca.key" \
  -CAcreateserial -out "${DIR}/tls.crt" -days 825 -extfile "${DIR}/san.cnf"
chmod 600 "${DIR}/ca.key" "${DIR}/tls.key"
rm -f "${DIR}/tls.csr"
echo "wrote ${DIR}/ca.crt and ${DIR}/tls.crt"
