#!/bin/bash
# The six-node lab is kubeadm, not minikube. This script does not start a cluster.
set -euo pipefail
echo "make deploy builds a kubeadm cluster on the six Debian 12 VMs in ansible/inventory/hosts.ini." >&2
echo "The same playbook also accepts Ubuntu 24.04." >&2
echo "minikube is only the optional local extra: make smoke (profile testy-smoke, .kube/smoke.config)." >&2
exit 1
