#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/.cache/testy-src"
REF="${TESTY_GIT_REF:-release/2.1.3}"
COMMIT="${TESTY_GIT_COMMIT:-3544c0f34640443c499fde2f9a52be30c863c519}"
URL="${TESTY_GIT_URL:-https://gitlab-pub.yadro.com/testy/testy.git}"
PROFILE="${MINIKUBE_PROFILE:-testy-smoke}"

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

API_HOST="${API_HOST:-api.testy.local}"
STAMP_FILE="${ROOT}/.cache/image-build.stamp"
WANT="${COMMIT} ${API_HOST}"
have_images=1
for image in testy-backend:2.1.3 testy-frontend:2.1.3 testy-fluentd:1.19.3; do
  if ! docker image inspect "${image}" >/dev/null 2>&1; then
    have_images=0
  fi
done
rebuilt=0
if [[ "${SKIP_IMAGE_BUILD:-}" == "1" && "${have_images}" == "1" ]]; then
  echo "local images already present, skip build"
elif [[ -f "${STAMP_FILE}" && "$(cat "${STAMP_FILE}")" == "${WANT}" && "${have_images}" == "1" ]]; then
  echo "images already built for ${WANT}"
else
  docker build -t testy-backend:2.1.3 -f "${ROOT}/images/backend/Dockerfile" "${SRC}/backend/testy"
  docker build -t testy-frontend:2.1.3 \
    --build-arg "NODE_HEAP=${NODE_HEAP:-2048}" \
    --build-arg "VITE_APP_API_ROOT=https://${API_HOST}" \
    -f "${ROOT}/images/frontend/Dockerfile" "${SRC}/frontend"
  docker build -t testy-fluentd:1.19.3 -f "${ROOT}/images/fluentd/Dockerfile" "${ROOT}/images/fluentd"
  mkdir -p "${ROOT}/.cache"
  printf '%s\n' "${WANT}" > "${STAMP_FILE}"
  rebuilt=1
fi

if [[ "${EXPORT_IMAGES:-}" == "1" ]]; then
  mkdir -p "${ROOT}/.cache/images"
  export_tar() {
    local image="$1" tar="$2"
    if [[ "${rebuilt}" == "0" && -f "${tar}" && -f "${STAMP_FILE}" && "$(cat "${STAMP_FILE}")" == "${WANT}" ]]; then
      echo "archive already exported: ${tar}"
      return
    fi
    docker save "${image}" -o "${tar}"
  }
  export_tar testy-backend:2.1.3 "${ROOT}/.cache/images/testy-backend.tar"
  export_tar testy-frontend:2.1.3 "${ROOT}/.cache/images/testy-frontend.tar"
  export_tar testy-fluentd:1.19.3 "${ROOT}/.cache/images/testy-fluentd.tar"
  if [[ ! -f "${STAMP_FILE}" ]]; then
    mkdir -p "${ROOT}/.cache"
    printf '%s\n' "${WANT}" > "${STAMP_FILE}"
  fi
fi

if [[ "${SKIP_MINIKUBE_LOAD:-}" == "1" ]]; then
  echo "skip minikube image load"
  exit 0
fi
export KUBECONFIG="${ROOT}/.kube/smoke.config"
export MINIKUBE_HOME="${ROOT}/.minikube"
mkdir -p "${ROOT}/.kube" "${MINIKUBE_HOME}"
for image in testy-backend:2.1.3 testy-frontend:2.1.3 testy-fluentd:1.19.3; do
  minikube image load "${image}" --profile="${PROFILE}"
done
echo "images loaded into ${PROFILE}"
