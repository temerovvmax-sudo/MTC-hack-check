#!/usr/bin/env python3
"""Render Gateway and TestY config with the inventory hostnames and MetalLB VIP."""

import re
import sys
from pathlib import Path

ROOT_INDEX = 1
UI_INDEX = 2
API_INDEX = 3
VIP_INDEX = 4
OUT_INDEX = 5

VIP_RE = re.compile(r"^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$")
HOST_RE = re.compile(r"^[A-Za-z0-9.-]+$")
NEEDLE = "        type: LoadBalancer\n        externalTrafficPolicy: Local\n"


def swap_hosts(text: str, ui_host: str, api_host: str) -> str:
    # Park the API name first so replacing the UI name cannot rewrite it.
    return (
        text.replace("api.testy.local", "\x00API\x00")
        .replace("testy.local", "\x00UI\x00")
        .replace("\x00API\x00", api_host)
        .replace("\x00UI\x00", ui_host)
    )


def main() -> None:
    root = Path(sys.argv[ROOT_INDEX])
    ui_host = sys.argv[UI_INDEX]
    api_host = sys.argv[API_INDEX]
    vip = sys.argv[VIP_INDEX]
    out = Path(sys.argv[OUT_INDEX])
    if not HOST_RE.match(ui_host) or not HOST_RE.match(api_host):
        raise SystemExit("gateway hostnames must be DNS labels")
    if not VIP_RE.match(vip):
        raise SystemExit(f"metallb_vip is not an IPv4 address: {vip}")
    out.mkdir(parents=True, exist_ok=True)

    gateway = (root / "k8s" / "gateway" / "gateway.yaml").read_text(encoding="utf-8")
    gateway = swap_hosts(gateway, ui_host, api_host)
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

    data = swap_hosts((root / "k8s" / "testy" / "data.yaml").read_text(encoding="utf-8"), ui_host, api_host)
    (out / "data.yaml").write_text(data, encoding="utf-8")
    print(f"rendered {out}")


if __name__ == "__main__":
    main()
