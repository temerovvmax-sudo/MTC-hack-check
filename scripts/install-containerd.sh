#!/bin/bash
set -euo pipefail

CONTAINERD_VERSION="${CONTAINERD_VERSION:?CONTAINERD_VERSION is required}"
RUNC_VERSION="${RUNC_VERSION:?RUNC_VERSION is required}"

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "containerd ${CONTAINERD_VERSION} is installed for x86_64, found $(uname -m)" >&2
  exit 1
fi

python3 - <<'PY'
import re
import subprocess
import sys

text = subprocess.check_output(["ldd", "--version"], text=True, stderr=subprocess.STDOUT)
match = re.search(r"(\d+)\.(\d+)", text)
if not match:
    sys.exit("could not read the glibc version from ldd --version")
major, minor = int(match.group(1)), int(match.group(2))
if (major, minor) < (2, 35):
    sys.exit(
        f"containerd official build needs glibc >= 2.35, found {major}.{minor}"
    )
PY

install_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

stamp="/var/lib/testy-lab/containerd.stamp"
want="${CONTAINERD_VERSION} ${RUNC_VERSION}"
config="/etc/containerd/config.toml"
need=0
if [[ ! -x /usr/local/bin/containerd || ! -x /usr/local/sbin/runc ]]; then
  need=1
fi
if [[ ! -f "${stamp}" || "$(cat "${stamp}")" != "${want}" ]]; then
  need=1
fi
if ! grep -q "SystemdCgroup = true" "${config}" 2>/dev/null; then
  need=1
fi
if ! grep -q "BinaryName = '/usr/local/sbin/runc'" "${config}" 2>/dev/null; then
  need=1
fi

if [[ "${need}" == "0" ]]; then
  install_root systemctl enable --now containerd
  exit 0
fi

install_root apt-mark unhold containerd >/dev/null 2>&1 || true
install_root apt-get remove -y containerd >/dev/null 2>&1 || true

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
curl -fsSL -o "${tmp}/containerd.tgz" \
  "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
curl -fsSL -o "${tmp}/runc.amd64" \
  "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64"
curl -fsSL -o "${tmp}/containerd.service" \
  "https://raw.githubusercontent.com/containerd/containerd/v${CONTAINERD_VERSION}/containerd.service"
tar -C "${tmp}" -xzf "${tmp}/containerd.tgz"
install_root install -d -m 0755 /usr/local/bin /usr/local/sbin /etc/containerd /var/lib/testy-lab
install_root install -m 0755 "${tmp}/bin/containerd" /usr/local/bin/containerd
install_root install -m 0755 "${tmp}/bin/containerd-shim-runc-v2" /usr/local/bin/containerd-shim-runc-v2
install_root install -m 0755 "${tmp}/bin/ctr" /usr/local/bin/ctr
if [[ -f "${tmp}/bin/containerd-stress" ]]; then
  install_root install -m 0755 "${tmp}/bin/containerd-stress" /usr/local/bin/containerd-stress
fi
install_root install -m 0755 "${tmp}/runc.amd64" /usr/local/sbin/runc
install_root install -m 0644 "${tmp}/containerd.service" /etc/systemd/system/containerd.service

install_root /usr/local/bin/containerd config default > "${tmp}/config.toml"
python3 - "${tmp}/config.toml" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
if "SystemdCgroup = false" not in text and "SystemdCgroup = true" not in text:
    raise SystemExit("containerd default config has no SystemdCgroup setting")
text = text.replace("SystemdCgroup = false", "SystemdCgroup = true")
old = "BinaryName = ''"
new = "BinaryName = '/usr/local/sbin/runc'"
if old not in text and new not in text:
    raise SystemExit("containerd default config has no runc BinaryName")
text = text.replace(old, new)
path.write_text(text, encoding="utf-8")
PY
install_root install -m 0644 "${tmp}/config.toml" "${config}"
printf '%s\n' "${want}" > "${tmp}/stamp"
install_root install -m 0644 "${tmp}/stamp" "${stamp}"
install_root systemctl daemon-reload
install_root systemctl enable containerd
install_root systemctl restart containerd
install_root systemctl is-active --quiet containerd
/usr/local/bin/containerd --version
/usr/local/sbin/runc --version
