#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="${ROOT}/.kube/lab.config"
SMOKE="${ROOT}/.kube/smoke.config"
if [[ -n "${KUBECONFIG:-}" ]]; then
  case "${KUBECONFIG}" in
    "${LAB}"|"${SMOKE}") ;;
    *)
      echo "refusing kubeconfig path: ${KUBECONFIG}" >&2
      exit 1
      ;;
  esac
else
  export KUBECONFIG="${LAB}"
fi
mkdir -p "${ROOT}/.kube" "${ROOT}/.secrets"
if [[ "${KUBECONFIG}" == "${SMOKE}" ]]; then
  export MINIKUBE_HOME="${ROOT}/.minikube"
  mkdir -p "${MINIKUBE_HOME}"
fi
exec "$@"
