ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
export KUBECONFIG := $(ROOT)/.kube/lab.config
export MINIKUBE_HOME := $(ROOT)/.minikube
export PATH := $(HOME)/.local/bin:$(PATH)

.PHONY: deploy verify lint passport

deploy:
	mkdir -p "$(ROOT)/.kube" "$(ROOT)/.minikube" "$(ROOT)/.secrets" "$(ROOT)/.cache"
	ansible-playbook "$(ROOT)/ansible/deploy.yml"

verify:
	mkdir -p "$(ROOT)/.kube" "$(ROOT)/.minikube" "$(ROOT)/.secrets"
	ansible-playbook "$(ROOT)/ansible/verify.yml"

lint:
	bash "$(ROOT)/scripts/lint.sh"

passport:
	python3 "$(ROOT)/docs/build_passport.py"
