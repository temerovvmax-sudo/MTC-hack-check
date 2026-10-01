#!/bin/bash
# Install pinned lab binaries under /usr/local/bin. Does not start a cluster.
set -euo pipefail
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.37.0}"
MINIKUBE_VERSION="${MINIKUBE_VERSION:-v1.39.0}"
HELM_VERSION="${HELM_VERSION:-v3.22.0}"
KUBECONFORM_VERSION="${KUBECONFORM_VERSION:-v0.8.0}"
INSTALL_MINIKUBE="${INSTALL_MINIKUBE:-1}"

need_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_kubectl() {
  if command -v kubectl >/dev/null && kubectl version --client -o json 2>/dev/null | python3 -c 'import json,sys; raise SystemExit(0 if json.load(sys.stdin)["clientVersion"]["gitVersion"]==sys.argv[1] else 1)' "${KUBECTL_VERSION}"; then
    return
  fi
  tmp="$(mktemp)"
  curl -fsSL -o "${tmp}" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  need_root install -m 0755 "${tmp}" /usr/local/bin/kubectl
  rm -f "${tmp}"
}

install_minikube() {
  if command -v minikube >/dev/null && [[ "$(minikube version --short)" == "${MINIKUBE_VERSION}" ]]; then
    return
  fi
  tmp="$(mktemp)"
  curl -fsSL -o "${tmp}" "https://github.com/kubernetes/minikube/releases/download/${MINIKUBE_VERSION}/minikube-linux-amd64"
  need_root install -m 0755 "${tmp}" /usr/local/bin/minikube
  rm -f "${tmp}"
}

install_helm() {
  if command -v helm >/dev/null && [[ "$(helm version --short --client | cut -d+ -f1)" == "${HELM_VERSION}" ]]; then
    return
  fi
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/helm.tgz" "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
  tar -C "${tmp}" -xzf "${tmp}/helm.tgz"
  need_root install -m 0755 "${tmp}/linux-amd64/helm" /usr/local/bin/helm
  rm -rf "${tmp}"
}

install_kubeconform() {
  if command -v kubeconform >/dev/null && [[ "$(kubeconform -v 2>/dev/null | awk '{print $1}')" == "${KUBECONFORM_VERSION}" ]]; then
    return
  fi
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/kc.tgz" "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz"
  tar -C "${tmp}" -xzf "${tmp}/kc.tgz"
  need_root install -m 0755 "${tmp}/kubeconform" /usr/local/bin/kubeconform
  rm -rf "${tmp}"
}

install_kubectl
if [[ "${INSTALL_MINIKUBE}" == "1" ]]; then
  install_minikube
fi
install_helm
install_kubeconform
if [[ "${INSTALL_MINIKUBE}" == "1" ]]; then
  echo "binaries ready: kubectl ${KUBECTL_VERSION}, minikube ${MINIKUBE_VERSION}, helm ${HELM_VERSION}, kubeconform ${KUBECONFORM_VERSION}"
else
  echo "binaries ready: kubectl ${KUBECTL_VERSION}, helm ${HELM_VERSION}, kubeconform ${KUBECONFORM_VERSION}"
fi
