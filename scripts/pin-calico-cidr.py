#!/usr/bin/env python3
import sys
from pathlib import Path

OLD = """            # - name: CALICO_IPV4POOL_CIDR
            #   value: \"192.168.0.0/16\""""


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: pin-calico-cidr.py MANIFEST CIDR")
    path, cidr = Path(sys.argv[1]), sys.argv[2]
    text = path.read_text(encoding="utf-8")
    new = (
        "            - name: CALICO_IPV4POOL_CIDR\n"
        f'              value: "{cidr}"'
    )
    if OLD in text:
        path.write_text(text.replace(OLD, new, 1), encoding="utf-8")
        return
    if f'value: "{cidr}"' in text and "CALICO_IPV4POOL_CIDR" in text:
        return
    raise SystemExit("calico manifest has no commented CALICO_IPV4POOL_CIDR")


if __name__ == "__main__":
    main()
