#!/bin/bash
# One-node smoke profile. Never uses the default kubeconfig.
set -euo pipefail
: "${KUBECONFIG:?KUBECONFIG must be the lab file}"
: "${MINIKUBE_HOME:?MINIKUBE_HOME must be the lab directory}"
case "${KUBECONFIG}" in
  */.kube/smoke.config) ;;
  *)
    echo "refusing kubeconfig ${KUBECONFIG}: smoke must use .kube/smoke.config" >&2
    exit 1
    ;;
esac
PROFILE="${MINIKUBE_PROFILE:-testy-smoke}"
if [[ "${PROFILE}" == "testy-lab" ]]; then
  echo "smoke must not reuse the six-node profile name testy-lab" >&2
  exit 1
fi
CPUS="${MINIKUBE_CPUS:-2}"
MEMORY="${MINIKUBE_MEMORY_MB:-3072}"
if [[ "${MEMORY}" -gt 3072 ]]; then
  echo "smoke node memory ${MEMORY} exceeds 3072 MiB" >&2
  exit 1
fi
DISK="${MINIKUBE_DISK:-12g}"
K8S="${KUBERNETES_VERSION:-v1.37.0}"

minikube start \
  --profile="${PROFILE}" \
  --driver=docker \
  --nodes=1 \
  --cpus="${CPUS}" \
  --memory="${MEMORY}" \
  --disk-size="${DISK}" \
  --kubernetes-version="${K8S}" \
  --cni=kindnet \
  --wait=all \
  --extra-config=kubelet.system-reserved=cpu=50m,memory=128Mi \
  --extra-config=kubelet.kube-reserved=cpu=50m,memory=128Mi \
  --extra-config="kubelet.eviction-hard=memory.available<80Mi"

minikube addons disable metrics-server --profile="${PROFILE}" >/dev/null 2>&1 || true
minikube addons disable dashboard --profile="${PROFILE}" >/dev/null 2>&1 || true
minikube addons disable storage-provisioner --profile="${PROFILE}" >/dev/null 2>&1 || true
minikube addons disable default-storageclass --profile="${PROFILE}" >/dev/null 2>&1 || true

kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
kubectl taint nodes --all node-role.kubernetes.io/master- >/dev/null 2>&1 || true
count="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
if [[ "${count}" != "1" ]]; then
  echo "smoke profile ${PROFILE} has ${count} nodes, expected 1" >&2
  exit 1
fi
kubectl get nodes -o wide
echo "smoke cluster ${PROFILE} is ready (${MEMORY} MiB, 1 node)"
