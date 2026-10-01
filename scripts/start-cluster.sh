#!/bin/bash
# Create the 6-node lab profile. KUBECONFIG must already be the lab file.
set -euo pipefail
: "${KUBECONFIG:?KUBECONFIG must be the lab file}"
: "${MINIKUBE_HOME:?MINIKUBE_HOME must be the lab directory}"
case "${KUBECONFIG}" in
  */.kube/lab.config) ;;
  *)
    echo "refusing kubeconfig ${KUBECONFIG}" >&2
    exit 1
    ;;
esac
PROFILE="${MINIKUBE_PROFILE:-testy-lab}"
NODES="${MINIKUBE_NODES:-6}"
CPUS="${MINIKUBE_CPUS:-2}"
MEMORY="${MINIKUBE_MEMORY_MB:-3584}"
DISK="${MINIKUBE_DISK:-12g}"
K8S="${KUBERNETES_VERSION:-v1.37.0}"

minikube start \
  --profile="${PROFILE}" \
  --driver=docker \
  --nodes="${NODES}" \
  --cpus="${CPUS}" \
  --memory="${MEMORY}" \
  --disk-size="${DISK}" \
  --kubernetes-version="${K8S}" \
  --cni=kindnet \
  --wait=all \
  --extra-config=kubelet.housekeeping-interval=10s

mapfile -t WORKERS < <(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
if [[ "${#WORKERS[@]}" -ne 5 ]]; then
  echo "expected 5 non-control-plane nodes, got ${#WORKERS[@]}" >&2
  printf ' %s\n' "${WORKERS[@]}" >&2
  exit 1
fi
for name in "${WORKERS[@]:0:3}"; do
  kubectl label node "${name}" testy.yadro.dev/pool=app --overwrite
  kubectl taint node "${name}" testy.yadro.dev/pool- || true
done
for name in "${WORKERS[@]:3:2}"; do
  kubectl label node "${name}" testy.yadro.dev/pool=gateway --overwrite
  kubectl taint node "${name}" testy.yadro.dev/pool=gateway:NoSchedule --overwrite
done
kubectl get nodes -L testy.yadro.dev/pool
echo "cluster ${PROFILE} is ready"
