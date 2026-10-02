#!/usr/bin/env python3
import ipaddress
import re
import sys
from pathlib import Path

DEFAULT_NODE_IPS = [
    "192.168.15.120",
    "192.168.15.121",
    "192.168.15.122",
    "192.168.15.123",
    "192.168.15.124",
    "192.168.15.125",
]
VIP_RE = re.compile(
    r"^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
)
HOST_RE = re.compile(r"^[A-Za-z0-9.-]+$")
NEEDLE = "        type: LoadBalancer\n        externalTrafficPolicy: Local\n"
API_NEEDLE = (
    '            cidr: 192.168.15.120/32\n'
    "      ports:\n"
    "        - protocol: TCP\n"
    "          port: 6443"
)


def format_node_blocks(ips: list[str]) -> str:
    return "\n".join(f"        - ipBlock:\n            cidr: {ip}/32" for ip in ips)


def swap_hosts(text: str, ui_host: str, api_host: str) -> str:
    return (
        text.replace("api.testy.local", "\x00API\x00")
        .replace("testy.local", "\x00UI\x00")
        .replace("\x00API\x00", api_host)
        .replace("\x00UI\x00", ui_host)
    )


def parse_ips(raw: str) -> list[str]:
    ips = [item.strip() for item in raw.split(",") if item.strip()]
    if len(ips) != 6 or len(set(ips)) != 6:
        raise SystemExit("expected 6 distinct node addresses")
    for ip in ips:
        if not VIP_RE.match(ip):
            raise SystemExit(f"node address is not IPv4: {ip}")
    return ips


def service_addresses(service_cidr: str) -> tuple[str, str]:
    network = ipaddress.ip_network(service_cidr, strict=True)
    if network.version != 4 or network.prefixlen > 24:
        raise SystemExit(f"service CIDR must be an IPv4 network of /24 or larger: {service_cidr}")
    base = int(network.network_address)
    return str(ipaddress.ip_address(base + 1)), str(ipaddress.ip_address(base + 10))


def check_network(node_cidr: str, pod_cidr: str, service_cidr: str, vip: str, node_ips: list[str]) -> None:
    nodes = ipaddress.ip_network(node_cidr, strict=True)
    pods = ipaddress.ip_network(pod_cidr, strict=True)
    services = ipaddress.ip_network(service_cidr, strict=True)
    if nodes.version != 4:
        raise SystemExit(f"node_cidr must be IPv4: {node_cidr}")
    if pods.overlaps(nodes):
        raise SystemExit(f"pod CIDR {pod_cidr} overlaps node CIDR {node_cidr}")
    if services.overlaps(nodes) or services.overlaps(pods):
        raise SystemExit(f"service CIDR {service_cidr} overlaps the node or pod CIDR")
    addresses = [ipaddress.ip_address(ip) for ip in node_ips]
    vip_address = ipaddress.ip_address(vip)
    if vip_address in addresses:
        raise SystemExit("metallb_vip must not be one of the node addresses")
    outside = [str(ip) for ip in [*addresses, vip_address] if ip not in nodes]
    if outside:
        raise SystemExit(f"these addresses are outside {node_cidr}: {', '.join(outside)}")
    service_addresses(service_cidr)


def render_policies(text: str, node_ips: list[str], node_cidr: str, cp_ip: str, service_cidr: str) -> str:
    default_block = format_node_blocks(DEFAULT_NODE_IPS)
    node_block = format_node_blocks(node_ips)
    if default_block not in text:
        raise SystemExit("network policies are missing the default node address block")
    text = text.replace(default_block, node_block)
    api_block = API_NEEDLE.replace("192.168.15.120", cp_ip)
    if API_NEEDLE not in text and api_block not in text:
        raise SystemExit("network policies are missing the control-plane API bypass")
    text = text.replace(API_NEEDLE, api_block)
    if "192.168.15.0/24" not in text and node_cidr not in text:
        raise SystemExit("network policies are missing the node CIDR egress block")
    text = text.replace("192.168.15.0/24", node_cidr)
    kubernetes_ip, dns_ip = service_addresses(service_cidr)
    text = text.replace("10.96.0.10/32", f"{dns_ip}/32")
    text = text.replace("10.96.0.1/32", f"{kubernetes_ip}/32")
    return text


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: render-lab-manifests.py check|render ...")
    command = sys.argv[1]
    if command == "check":
        if len(sys.argv) != 7:
            raise SystemExit(
                "usage: render-lab-manifests.py check NODE_CIDR POD_CIDR SERVICE_CIDR VIP NODE_IPS"
            )
        node_ips = parse_ips(sys.argv[6])
        check_network(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], node_ips)
        print("lab network ok")
        return
    if command != "render":
        raise SystemExit(f"unknown command {command}")
    if len(sys.argv) != 12:
        raise SystemExit(
            "usage: render-lab-manifests.py render ROOT UI API VIP "
            "NODE_CIDR CP_IP POD_CIDR SERVICE_CIDR NODE_IPS OUT"
        )
    root = Path(sys.argv[2])
    ui_host = sys.argv[3]
    api_host = sys.argv[4]
    vip = sys.argv[5]
    node_cidr = sys.argv[6]
    cp_ip = sys.argv[7]
    pod_cidr = sys.argv[8]
    service_cidr = sys.argv[9]
    node_ips = parse_ips(sys.argv[10])
    out = Path(sys.argv[11])
    if not HOST_RE.match(ui_host) or not HOST_RE.match(api_host):
        raise SystemExit("gateway hostnames must be DNS labels")
    if not VIP_RE.match(vip) or not VIP_RE.match(cp_ip):
        raise SystemExit("metallb_vip and the control-plane address must be IPv4")
    if cp_ip not in node_ips:
        raise SystemExit("control-plane address is not one of the node addresses")
    check_network(node_cidr, pod_cidr, service_cidr, vip, node_ips)
    out.mkdir(parents=True, exist_ok=True)

    gateway = swap_hosts((root / "k8s" / "gateway" / "gateway.yaml").read_text(encoding="utf-8"), ui_host, api_host)
    if NEEDLE not in gateway:
        raise SystemExit("gateway.yaml is missing the LoadBalancer block the renderer expects")
    insert = (
        "        type: LoadBalancer\n"
        "        externalTrafficPolicy: Local\n"
        "        annotations:\n"
        f"          metallb.universe.tf/loadBalancerIPs: {vip}\n"
    )
    gateway = gateway.replace(NEEDLE, insert, 1)
    (out / "gateway.yaml").write_text(gateway, encoding="utf-8")

    for name in ("data.yaml", "app.yaml"):
        source = root / "k8s" / "testy" / name
        (out / name).write_text(swap_hosts(source.read_text(encoding="utf-8"), ui_host, api_host), encoding="utf-8")

    policies = (root / "k8s" / "network" / "policies.yaml").read_text(encoding="utf-8")
    (out / "policies.yaml").write_text(
        render_policies(policies, node_ips, node_cidr, cp_ip, service_cidr),
        encoding="utf-8",
    )
    print(f"rendered {out}")


if __name__ == "__main__":
    main()
