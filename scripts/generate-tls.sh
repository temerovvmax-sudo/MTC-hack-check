#!/bin/bash
# Self-signed lab CA and a certificate for the Gateway hostnames.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UI_HOST="${UI_HOST:-testy.local}"
API_HOST="${API_HOST:-api.testy.local}"
case "${UI_HOST}${API_HOST}" in
  *[!A-Za-z0-9.-]*)
    echo "gateway hostnames must be DNS names" >&2
    exit 1
    ;;
esac
DIR="${ROOT}/.secrets/tls"
mkdir -p "${DIR}"
chmod 700 "${ROOT}/.secrets" "${DIR}"
WANT="${UI_HOST} ${API_HOST}"
if [[ -f "${DIR}/ca.crt" && -f "${DIR}/tls.crt" && -f "${DIR}/tls.key" && -f "${DIR}/hosts" && "$(cat "${DIR}/hosts")" == "${WANT}" ]]; then
  echo "tls material already present in ${DIR}"
  exit 0
fi
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout "${DIR}/ca.key" -out "${DIR}/ca.crt" \
  -subj "/CN=TestY Lab CA"
openssl req -newkey rsa:2048 -nodes \
  -keyout "${DIR}/tls.key" -out "${DIR}/tls.csr" \
  -subj "/CN=${UI_HOST}"
cat > "${DIR}/san.cnf" <<EOF
subjectAltName=DNS:${UI_HOST},DNS:${API_HOST}
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
EOF
openssl x509 -req -in "${DIR}/tls.csr" -CA "${DIR}/ca.crt" -CAkey "${DIR}/ca.key" \
  -CAcreateserial -out "${DIR}/tls.crt" -days 825 -extfile "${DIR}/san.cnf"
chmod 600 "${DIR}/ca.key" "${DIR}/tls.key"
rm -f "${DIR}/tls.csr"
printf '%s\n' "${WANT}" > "${DIR}/hosts"
chmod 600 "${DIR}/hosts"
echo "wrote ${DIR}/ca.crt and ${DIR}/tls.crt"
