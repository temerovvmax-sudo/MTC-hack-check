#!/bin/bash
# Clone pinned TestY, build lab images, load them into every minikube node.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${ROOT}/.kube/lab.config"
export MINIKUBE_HOME="${ROOT}/.minikube"
SRC="${ROOT}/.cache/testy-src"
REF="${TESTY_GIT_REF:-release/2.1.3}"
COMMIT="${TESTY_GIT_COMMIT:-3544c0f34640443c499fde2f9a52be30c863c519}"
URL="${TESTY_GIT_URL:-https://gitlab-pub.yadro.com/testy/testy.git}"
PROFILE="${MINIKUBE_PROFILE:-testy-lab}"

if [[ ! -d "${SRC}/.git" ]] || [[ "$(git -C "${SRC}" rev-parse HEAD)" != "${COMMIT}" ]]; then
  rm -rf "${SRC}"
  git clone --depth 1 --branch "${REF}" "${URL}" "${SRC}"
fi
if [[ "$(git -C "${SRC}" rev-parse HEAD)" != "${COMMIT}" ]]; then
  echo "TestY ${REF} resolved to $(git -C "${SRC}" rev-parse HEAD), expected ${COMMIT}" >&2
  exit 1
fi

install -m 0644 "${ROOT}/images/backend/gunicorn.conf.py" "${SRC}/backend/testy/scripts/gunicorn.conf.py"
install -m 0755 "${ROOT}/images/backend/entrypoint.sh" "${SRC}/backend/testy/scripts/entrypoint.sh"
install -m 0644 "${ROOT}/images/frontend/nginx.conf" "${SRC}/frontend/nginx.conf"

docker build -t testy-backend:2.1.3 -f "${ROOT}/images/backend/Dockerfile" "${SRC}/backend/testy"
docker build -t testy-frontend:2.1.3 -f "${ROOT}/images/frontend/Dockerfile" "${SRC}/frontend"
docker build -t testy-fluentd:1.19.3 -f "${ROOT}/images/fluentd/Dockerfile" "${ROOT}/images/fluentd"

for image in testy-backend:2.1.3 testy-frontend:2.1.3 testy-fluentd:1.19.3; do
  minikube image load "${image}" --profile="${PROFILE}"
done
echo "images loaded into ${PROFILE}"
