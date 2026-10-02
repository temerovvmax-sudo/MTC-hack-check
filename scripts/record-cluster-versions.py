#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from pathlib import Path


def kubectl_json(args: list[str]) -> dict:
    result = subprocess.run(
        ["kubectl", *args, "-o", "json"],
        check=True,
        text=True,
        capture_output=True,
    )
    return json.loads(result.stdout)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: record-cluster-versions.py OUTPUT")
    output = Path(sys.argv[1])
    nodes = kubectl_json(["get", "nodes"])
    pods = kubectl_json(["get", "pods", "-A"])
    lines = [
        f"containerd_requested={os.environ['CONTAINERD_VERSION']}",
        f"runc_requested={os.environ['RUNC_VERSION']}",
        f"pod_cidr={os.environ['POD_CIDR']}",
        f"service_cidr={os.environ['SERVICE_CIDR']}",
        f"node_cidr={os.environ['NODE_CIDR']}",
        f"metallb_vip={os.environ['METALLB_VIP']}",
        f"ui_host={os.environ['UI_HOST']}",
        f"api_host={os.environ['API_HOST']}",
        f"kube_prometheus_stack={os.environ['KUBE_PROMETHEUS_STACK_VERSION']}",
        f"prometheus_operator={os.environ['PROMETHEUS_OPERATOR_VERSION']}",
        f"alertmanager={os.environ['ALERTMANAGER_VERSION']}",
        f"prometheus={os.environ['PROMETHEUS_VERSION']}",
        f"grafana={os.environ['GRAFANA_VERSION']}",
        f"loki={os.environ['LOKI_VERSION']}",
        f"loki_chart={os.environ['LOKI_CHART_VERSION']}",
        f"envoy_gateway_chart={os.environ['ENVOY_GATEWAY_CHART_VERSION']}",
    ]
    runtime_versions = set()
    for node in nodes["items"]:
        info = node["status"]["nodeInfo"]
        runtime = info.get("containerRuntimeVersion", "")
        runtime_versions.add(runtime)
        lines.append(
            "node {name} kubelet={kubelet} runtime={runtime}".format(
                name=node["metadata"]["name"],
                kubelet=info.get("kubeletVersion", ""),
                runtime=runtime,
            )
        )
    images = set()
    for pod in pods["items"]:
        for status in pod.get("status", {}).get("containerStatuses", []):
            images.add(status.get("image", ""))
        for container in pod.get("spec", {}).get("containers", []):
            images.add(container.get("image", ""))
    for image in sorted(images):
        if image:
            lines.append(f"image {image}")
    blob = "\n".join(lines) + "\n"
    expected_runtime = f"containerd://{os.environ['CONTAINERD_VERSION']}"
    if not runtime_versions or any(not runtime.startswith(expected_runtime) for runtime in runtime_versions):
        raise SystemExit(f"nodes are not running {expected_runtime}: {sorted(runtime_versions)}")
    checks = {
        "prometheus-operator:": os.environ["PROMETHEUS_OPERATOR_VERSION"],
        "alertmanager:": os.environ["ALERTMANAGER_VERSION"],
        "prometheus:": os.environ["PROMETHEUS_VERSION"],
        "grafana:": os.environ["GRAFANA_VERSION"],
        "loki:": os.environ["LOKI_VERSION"],
    }
    missing = []
    for prefix, version in checks.items():
        needle = prefix + version
        if not any(needle in image for image in images):
            missing.append(needle)
    if missing:
        raise SystemExit("running images do not include " + ", ".join(missing))
    output.write_text(blob, encoding="utf-8")
    os.chmod(output, 0o644)
    print(f"wrote {output}")


if __name__ == "__main__":
    main()
