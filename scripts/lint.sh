#!/bin/bash
# Validate YAML and render Helm charts through kubeconform. No cluster required.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:${PATH}"
export HELM_CACHE_HOME="${ROOT}/.cache/helm"
export HELM_CONFIG_HOME="${ROOT}/.cache/helm-config"
export HELM_DATA_HOME="${ROOT}/.cache/helm-data"
mkdir -p "${HELM_CACHE_HOME}" "${HELM_CONFIG_HOME}" "${HELM_DATA_HOME}"

python3 -m yamllint -c "${ROOT}/.yamllint.yml" "${ROOT}"

python3 - "${ROOT}" <<'PY'
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
files = list((root / "k8s/monitoring/dashboards").glob("*.json"))
files.append(root / "k8s/monitoring/dashboards.yaml")
for path in (root / "k8s/monitoring/dashboards").glob("*.json"):
    json.loads(path.read_text())
    print(f"json ok {path.relative_to(root)}")
PY

RENDER="${ROOT}/.cache/rendered"
rm -rf "${RENDER}"
mkdir -p "${RENDER}"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo update >/dev/null

helm template eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.2 \
  --namespace envoy-gateway-system \
  -f "${ROOT}/k8s/gateway/values-envoy.yaml" \
  > "${RENDER}/envoy-gateway.yaml"

helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 91.8.2 \
  --namespace monitoring \
  -f "${ROOT}/k8s/monitoring/values-prometheus.yaml" \
  > "${RENDER}/kube-prometheus-stack.yaml"

helm template loki grafana/loki \
  --version 6.55.0 \
  --namespace logging \
  -f "${ROOT}/k8s/monitoring/values-loki.yaml" \
  > "${RENDER}/loki.yaml"

K8S_VERSION="1.37.0"

kubeconform -summary -strict \
  -kubernetes-version "${K8S_VERSION}" \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -ignore-missing-schemas \
  "${ROOT}/k8s/namespaces.yaml" \
  "${ROOT}/k8s/testy" \
  "${ROOT}/k8s/gateway/gateway.yaml" \
  "${ROOT}/k8s/logging" \
  "${ROOT}/k8s/monitoring/dashboards.yaml" \
  "${RENDER}"

echo "lint ok (kubeconform kubernetes schema ${K8S_VERSION})"
