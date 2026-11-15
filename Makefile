# kagent-on-substrate: kagent is the runtime, Agent Substrate places and routes it.
# `make help` lists targets. Run them top to bottom for the walkthrough.

CLUSTER          ?= kagent-substrate
NAMESPACE        ?= kagent
KAGENT_VERSION   ?= v1.0.1
ATE_VERSION      ?= v1.0.0
KAGENT           ?= kagent
KUBECTL          ?= kubectl
# Worker image: reuse the one the kagent chart gave the default pool, so it always
# matches the installed Substrate version. Override with WORKER_IMAGE=... if needed.
WORKER_IMAGE     ?= $(shell $(KUBECTL) get workerpool kagent-default -n $(NAMESPACE) -o jsonpath='{.spec.workerImage}' 2>/dev/null)

.DEFAULT_GOAL := help
.PHONY: help tools cluster install ate-cli apply status demo validate clean destroy

help: ## Show this help
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z_-]+:.*## /{printf "  %-10s %s\n",$$1,$$2}' $(MAKEFILE_LIST)

tools: ## Check required CLIs are on PATH
	@for t in docker kind kubectl helm jq $(KAGENT); do \
	  command -v $$t >/dev/null 2>&1 && echo "ok      $$t" || { echo "MISSING $$t"; missing=1; }; \
	done; [ -z "$$missing" ]

cluster: ## Create the kind cluster (Kubernetes 1.37, kindest/node:v1.37.0, kind >= 0.32.0)
	kind create cluster --config cluster/kind-config.yaml
	$(KUBECTL) api-resources --api-group=certificates.k8s.io

install: ## Install kagent OSS (CLI): CRDs, Agent Substrate, dev PostgreSQL, kagent. Needs OPENAI_API_KEY
	@test -n "$$OPENAI_API_KEY" || { echo "export OPENAI_API_KEY first (it is read from your shell, never from this repo)"; exit 1; }
	$(KAGENT) --config install/kagent-config.yaml install --namespace $(NAMESPACE)
	$(KUBECTL) rollout status deployment/kagent-controller -n $(NAMESPACE) --timeout=300s
	$(KUBECTL) get workerpools -n $(NAMESPACE)

ate-cli: ## Install the kubectl-ate plugin from the Agent Substrate release
	@os=$$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/'); \
	curl -fsSL -o /tmp/kubectl-ate "https://github.com/kagent-dev/substrate/releases/download/$(ATE_VERSION)/kubectl-ate-$$os-$$arch" && \
	chmod +x /tmp/kubectl-ate && \
	echo "installing to /usr/local/bin/kubectl-ate (sudo)" && sudo mv /tmp/kubectl-ate /usr/local/bin/kubectl-ate && \
	$(KUBECTL) ate --help | head -3

apply: ## Apply two WorkerPools, two Harnesses, one AgentTemplate, two Agents
	@test -n "$(WORKER_IMAGE)" || { echo "could not read WorkerPool kagent-default; is kagent installed?"; exit 1; }
	@echo "worker image: $(WORKER_IMAGE)"
	@for f in manifests/*.yaml; do \
	  sed 's|$${WORKER_IMAGE}|$(WORKER_IMAGE)|g' $$f | $(KUBECTL) apply -f - || exit 1; \
	done
	$(KUBECTL) wait --for=condition=Ready agent/triage-interactive agent/triage-batch -n $(NAMESPACE) --timeout=300s
	$(KUBECTL) get workerpools,harnesses,agenttemplates,agents -n $(NAMESPACE)

status: ## Who owns what right now: workers, actors, agents
	$(KUBECTL) get workerpools -n $(NAMESPACE)
	$(KUBECTL) ate get workers
	$(KUBECTL) ate get actors -a $(NAMESPACE)
	$(KAGENT) agent list

demo: ## Run scripts/demo.sh (sessions, suspend/resume, burst on the batch pool)
	./scripts/demo.sh

validate: ## Dry-run every manifest against the real CRDs on a throwaway kube-apiserver (no Docker)
	./hack/validate.sh

clean: ## Remove demo sessions and the resources this repo applied
	-@$(KAGENT) agent session list -o json | jq -r '.sessions[] | select(.agent.name | test("^triage-")) | .id' | xargs -n1 $(KAGENT) agent session delete
	-@for f in manifests/*.yaml; do sed 's|$${WORKER_IMAGE}|unused|g' $$f | $(KUBECTL) delete -f - --ignore-not-found; done

destroy: ## Delete the kind cluster
	kind delete cluster --name $(CLUSTER)
