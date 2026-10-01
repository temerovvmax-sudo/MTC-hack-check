#!/bin/bash
# Prove Gateway TLS via the MetalLB VIP, one Prometheus target, and an access log in Loki.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${ROOT}/.kube/lab.config"
export PATH="${HOME}/.local/bin:${PATH}"
unset MINIKUBE_HOME || true

if [[ ! -f "${KUBECONFIG}" ]]; then
  echo "lab kubeconfig is missing: ${KUBECONFIG}" >&2
  echo "run make deploy first" >&2
  exit 2
fi
case "${KUBECONFIG}" in
  */.kube/lab.config) ;;
  *)
    echo "refusing kubeconfig ${KUBECONFIG}" >&2
    exit 1
    ;;
esac

python3 - "${ROOT}" <<'PY'
import json
import os
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

root = Path(sys.argv[1])
env = os.environ.copy()
kubeconfig = str(root / ".kube" / "lab.config")
env["KUBECONFIG"] = kubeconfig
env.pop("MINIKUBE_HOME", None)
vip_expected = os.environ["METALLB_VIP"]
ui_host = os.environ.get("UI_HOST", "testy.local")
api_host = os.environ.get("API_HOST", "api.testy.local")

def run(args, check=True, input_text=None):
    print("+", " ".join(args), flush=True)
    result = subprocess.run(args, text=True, input=input_text, capture_output=True, env=env)
    if result.stdout:
        print(result.stdout, end="" if result.stdout.endswith("\n") else "\n")
    if result.returncode != 0 and check:
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        raise SystemExit(result.returncode)
    return result

nodes = json.loads(run(["kubectl", "get", "nodes", "-o", "json"]).stdout)
if len(nodes["items"]) != 6:
    print(f"expected 6 nodes, found {len(nodes['items'])}", file=sys.stderr)
    raise SystemExit(1)
gateway = []
app = []
control = []
for node in nodes["items"]:
    labels = node["metadata"].get("labels", {})
    name = node["metadata"]["name"]
    if "node-role.kubernetes.io/control-plane" in labels:
        control.append(name)
    if labels.get("testy.yadro.dev/pool") == "gateway":
        gateway.append(name)
        taints = node["spec"].get("taints", [])
        ok = any(
            t.get("key") == "testy.yadro.dev/pool"
            and t.get("value") == "gateway"
            and t.get("effect") == "NoSchedule"
            for t in taints
        )
        if not ok:
            print(f"gateway node {name} is missing the NoSchedule taint", file=sys.stderr)
            raise SystemExit(1)
    elif labels.get("testy.yadro.dev/pool") == "app":
        app.append(name)
print(f"control-plane: {control}")
print(f"gateway nodes: {gateway}")
print(f"app nodes: {app}")
if len(control) != 1 or len(gateway) != 2 or len(app) != 3:
    print("expected 1 control-plane, 3 app nodes and 2 gateway nodes", file=sys.stderr)
    raise SystemExit(1)

pods = json.loads(run([
    "kubectl", "get", "pods", "-A",
    "-l", "gateway.envoyproxy.io/owning-gateway-name=testy",
    "-o", "json",
]).stdout)
envoy_nodes = []
for pod in pods["items"]:
    if pod["status"].get("phase") != "Running":
        continue
    node_name = pod["spec"].get("nodeName")
    envoy_nodes.append(node_name)
    if node_name not in gateway:
        print(f"envoy pod {pod['metadata']['name']} is on {node_name}, not a gateway node", file=sys.stderr)
        raise SystemExit(1)
if len(envoy_nodes) < 1:
    print("no running Envoy data-plane pod", file=sys.stderr)
    raise SystemExit(1)
print(f"envoy data plane nodes: {envoy_nodes}")

services = json.loads(run([
    "kubectl", "get", "svc", "-A",
    "-l", "gateway.envoyproxy.io/owning-gateway-name=testy",
    "-o", "json",
]).stdout)
vip = None
for item in services["items"]:
    if item["spec"].get("type") != "LoadBalancer":
        continue
    ingress = item.get("status", {}).get("loadBalancer", {}).get("ingress") or []
    if ingress and ingress[0].get("ip"):
        vip = ingress[0]["ip"]
if vip != vip_expected:
    print(f"gateway LoadBalancer IP is {vip}, inventory metallb_vip is {vip_expected}", file=sys.stderr)
    raise SystemExit(1)
print(f"gateway VIP {vip}")

ca = root / ".secrets" / "tls" / "ca.crt"
probe = f"probe=lab{int(time.time())}"
ui = run([
    "curl", "-fsS", "--cacert", str(ca),
    "--resolve", f"{ui_host}:443:{vip}",
    f"https://{ui_host}/",
])
if "TestY TMS" not in ui.stdout:
    print("UI body did not contain TestY TMS", file=sys.stderr)
    raise SystemExit(1)
print("UI route returned TestY TMS")

api = run([
    "curl", "-fsS", "--cacert", str(ca),
    "--resolve", f"{api_host}:443:{vip}",
    f"https://{api_host}/healthcheck/?{probe}",
])
if '"status": "ok"' not in api.stdout.replace(" ", "") and '"status":"ok"' not in api.stdout.replace(" ", ""):
    print("API body was not {\"status\": \"ok\"}", file=sys.stderr)
    print(api.stdout)
    raise SystemExit(1)
print("API route returned status ok")

redirect = run([
    "curl", "-sS", "-D", "-", "-o", "/dev/null",
    "--resolve", f"{ui_host}:80:{vip}",
    f"http://{ui_host}/",
])
if "301" not in redirect.stdout:
    print(redirect.stdout)
    print("HTTP listener did not redirect", file=sys.stderr)
    raise SystemExit(1)
print("HTTP redirected toward HTTPS")

def port_forward(namespace, service, local_port, remote_port):
    proc = subprocess.Popen(
        ["kubectl", "port-forward", "-n", namespace, service, f"{local_port}:{remote_port}"],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    time.sleep(2)
    if proc.poll() is not None:
        print(proc.stdout.read() if proc.stdout else "port-forward failed", file=sys.stderr)
        raise SystemExit(1)
    return proc

prom = port_forward("monitoring", "svc/kube-prometheus-stack-prometheus", 19090, 9090)
try:
    query = run([
        "curl", "-fsS", "-G", "http://127.0.0.1:19090/api/v1/query",
        "--data-urlencode", 'query=up{job="kubelet"}',
    ])
finally:
    prom.terminate()
payload = json.loads(query.stdout)
results = payload.get("data", {}).get("result", [])
up = [item for item in results if float(item["value"][1]) >= 1]
if payload.get("status") != "success" or not up:
    print(query.stdout)
    print('Prometheus query up{job="kubelet"} returned no up target', file=sys.stderr)
    raise SystemExit(1)
sample = up[0].get("metric", {}).get("instance", "kubelet")
print(f'Prometheus up{{job="kubelet"}} has {len(up)} target(s); one is {sample}')

logql = '{job="testy-access"} |= "testy-access" |= "' + probe + '"'
found = False
loki = port_forward("logging", "svc/loki", 13100, 3100)
try:
    for _ in range(20):
        encoded = urllib.parse.urlencode({"query": logql})
        result = subprocess.run(
            ["curl", "-fsS", f"http://127.0.0.1:13100/loki/api/v1/query?{encoded}"],
            text=True, capture_output=True, env=env,
        )
        if result.returncode == 0:
            body = json.loads(result.stdout)
            streams = body.get("data", {}).get("result", [])
            if streams:
                print(result.stdout)
                found = True
                break
        time.sleep(3)
finally:
    loki.terminate()
if not found:
    print(f"Loki did not contain an access log for {probe}", file=sys.stderr)
    raise SystemExit(1)
print(f"Loki has an access log line for {probe}")
print("verify ok")
PY
