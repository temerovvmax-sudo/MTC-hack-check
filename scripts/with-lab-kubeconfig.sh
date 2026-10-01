#!/bin/bash
# Run a command with the lab kubeconfig. Never touches ~/.kube/config.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${ROOT}/.kube/lab.config"
export MINIKUBE_HOME="${ROOT}/.minikube"
mkdir -p "${ROOT}/.kube" "${ROOT}/.minikube" "${ROOT}/.secrets"
case "${KUBECONFIG}" in
  */.kube/lab.config) ;;
  *)
    echo "refusing kubeconfig path: ${KUBECONFIG}" >&2
    exit 1
    ;;
esac
exec "$@"
