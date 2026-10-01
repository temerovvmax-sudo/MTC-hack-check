ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
export KUBECONFIG := $(ROOT)/.kube/lab.config
export PATH := $(HOME)/.local/bin:$(PATH)
INVENTORY := $(ROOT)/ansible/inventory/hosts.ini

.PHONY: deploy verify lint passport smoke

deploy:
	@test -f "$(INVENTORY)" || { echo "Скопируйте ansible/inventory/hosts.example.ini в ansible/inventory/hosts.ini и заполните его."; exit 1; }
	mkdir -p "$(ROOT)/.kube" "$(ROOT)/.secrets" "$(ROOT)/.cache"
	ansible-playbook -i "$(INVENTORY)" "$(ROOT)/ansible/deploy.yml"

verify:
	@test -f "$(INVENTORY)" || { echo "Скопируйте ansible/inventory/hosts.example.ini в ansible/inventory/hosts.ini и заполните его."; exit 1; }
	mkdir -p "$(ROOT)/.kube" "$(ROOT)/.secrets"
	ansible-playbook -i "$(INVENTORY)" "$(ROOT)/ansible/verify.yml"

smoke:
	mkdir -p "$(ROOT)/.kube" "$(ROOT)/.minikube" "$(ROOT)/.secrets" "$(ROOT)/.cache"
	env KUBECONFIG="$(ROOT)/.kube/smoke.config" MINIKUBE_HOME="$(ROOT)/.minikube" \
	  ansible-playbook -i "$(ROOT)/ansible/inventory/hosts.yml" "$(ROOT)/ansible/smoke.yml"

lint:
	bash "$(ROOT)/scripts/lint.sh"

passport:
	python3 "$(ROOT)/docs/build_passport.py"
