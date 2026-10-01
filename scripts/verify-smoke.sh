#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${ROOT}/.kube/smoke.config"
export MINIKUBE_HOME="${ROOT}/.minikube"
export PATH="${HOME}/.local/bin:${PATH}"
PROFILE="${MINIKUBE_PROFILE:-testy-smoke}"

if [[ ! -f "${KUBECONFIG}" ]]; then
  echo "lab kubeconfig is missing: ${KUBECONFIG}" >&2
  exit 2
fi
case "${KUBECONFIG}" in
  */.kube/smoke.config) ;;
  *)
    echo "refusing kubeconfig ${KUBECONFIG}" >&2
    exit 1
    ;;
esac

python3 - "${ROOT}" "${PROFILE}" <<'PY'
import json
import os
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

root = Path(sys.argv[1])
profile = sys.argv[2]
env = os.environ.copy()
kubeconfig = str(root / ".kube" / "smoke.config")
env["KUBECONFIG"] = kubeconfig
env["MINIKUBE_HOME"] = str(root / ".minikube")

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
if len(nodes["items"]) != 1:
    print(f"smoke expected 1 node, found {len(nodes['items'])}", file=sys.stderr)
    raise SystemExit(1)
print(f"smoke node: {nodes['items'][0]['metadata']['name']}")

ip = run(["minikube", "ip", "-p", profile]).stdout.strip()
services = json.loads(run([
    "kubectl", "get", "svc", "-A",
    "-l", "gateway.envoyproxy.io/owning-gateway-name=testy",
    "-o", "json",
]).stdout)
https_port = http_port = None
for item in services["items"]:
    for port in item["spec"].get("ports", []):
        if port.get("port") == 443 and port.get("nodePort"):
            https_port = port["nodePort"]
        if port.get("port") == 80 and port.get("nodePort"):
            http_port = port["nodePort"]
if not https_port or not http_port:
    print("gateway NodePorts were not found", file=sys.stderr)
    raise SystemExit(1)
print(f"gateway https nodePort {https_port}, http nodePort {http_port}, node ip {ip}")

ca = root / ".secrets" / "tls" / "ca.crt"
probe = f"probe=lab{int(time.time())}"
ui = run([
    "curl", "-fsS", "--cacert", str(ca),
    "--resolve", f"testy.local:{https_port}:{ip}",
    f"https://testy.local:{https_port}/",
])
if "TestY TMS" not in ui.stdout:
    print("UI body did not contain TestY TMS", file=sys.stderr)
    raise SystemExit(1)
print("UI route returned TestY TMS")

api = run([
    "curl", "-fsS", "--cacert", str(ca),
    "--resolve", f"api.testy.local:{https_port}:{ip}",
    f"https://api.testy.local:{https_port}/healthcheck/?{probe}",
])
compact = api.stdout.replace(" ", "")
if '"status":"ok"' not in compact:
    print("API body was not {\"status\": \"ok\"}", file=sys.stderr)
    print(api.stdout)
    raise SystemExit(1)
print("API route returned status ok")

def port_forward(namespace, service, local_port, remote_port, path):
    proc = subprocess.Popen(
        ["kubectl", "port-forward", "-n", namespace, service, f"{local_port}:{remote_port}"],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    deadline = time.time() + 30
    while time.time() < deadline:
        if proc.poll() is not None:
            print(proc.stdout.read() if proc.stdout else "port-forward failed", file=sys.stderr)
            raise SystemExit(1)
        probe_cmd = subprocess.run(
            ["curl", "-fsS", "-o", "/dev/null", f"http://127.0.0.1:{local_port}{path}"],
            env=env,
        )
        if probe_cmd.returncode == 0:
            return proc
        time.sleep(0.5)
    proc.terminate()
    print(f"port-forward {service} did not open", file=sys.stderr)
    raise SystemExit(1)

prom = port_forward("monitoring", "svc/prometheus", 19090, 9090, "/-/ready")
try:
    query = run([
        "curl", "-fsS", "-G", "http://127.0.0.1:19090/api/v1/query",
        "--data-urlencode", 'query=sum(up{job="prometheus"})',
    ])
finally:
    prom.terminate()
payload = json.loads(query.stdout)
results = payload.get("data", {}).get("result", [])
if payload.get("status") != "success" or not results:
    print(query.stdout)
    print("Prometheus query returned no series", file=sys.stderr)
    raise SystemExit(1)
value = float(results[0]["value"][1])
if value < 1:
    print(query.stdout)
    raise SystemExit(1)
print(f'Prometheus sum(up{{job="prometheus"}}) = {value}')

logql = '{job="testy-access"} |= "testy-access" |= "' + probe + '"'
found = False
loki = port_forward("logging", "svc/loki", 13100, 3100, "/ready")
try:
    for _ in range(24):
        now = int(time.time())
        encoded = urllib.parse.urlencode({
            "query": logql,
            "start": str(now - 15 * 60),
            "end": str(now + 30),
            "limit": "5",
        })
        result = subprocess.run(
            ["curl", "-fsS", f"http://127.0.0.1:13100/loki/api/v1/query_range?{encoded}"],
            text=True, capture_output=True, env=env,
        )
        if result.returncode == 0:
            body = json.loads(result.stdout)
            streams = body.get("data", {}).get("result", [])
            if streams:
                print(result.stdout[:2000])
                found = True
                break
        time.sleep(5)
finally:
    loki.terminate()
if not found:
    print(f"Loki did not contain an access log for {probe}", file=sys.stderr)
    raise SystemExit(1)
print(f"Loki has an access log line for {probe}")
print("smoke verify ok")
PY
