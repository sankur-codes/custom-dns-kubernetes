# ── Configuration ──────────────────────────────────────────────────
# All config comes from config.env. Edit that file to change defaults.

include config.env

# Kind needs this env var when using Podman
export KIND_EXPERIMENTAL_PROVIDER := $(CONTAINER_CLI)

.PHONY: help prereqs cluster-up deploy verify demo demo-failover status clean \
        traffic traffic-stop \
        monitoring prometheus-ui grafana-ui \
        azure-infra azure-cluster azure-deploy azure-verify azure-failover \
        azure-demo azure-status azure-clean

# ═══════════════════════════════════════════════════════════════════
#  Help
# ═══════════════════════════════════════════════════════════════════

help: ## Show available targets
	@echo ""
	@echo "Custom DNS Demo — Makefile Targets"
	@echo "======================================"
	@echo ""
	@echo "  Kind (local):"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | grep -v 'azure-' | grep -v 'prometheus-\|grafana-' | \
	    awk 'BEGIN {FS = ":.*?## "}; {printf "    \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Monitoring:"
	@grep -E '^(monitoring|prometheus-|grafana-)[a-zA-Z_-]*:.*?## .*$$' $(MAKEFILE_LIST) | \
	    awk 'BEGIN {FS = ":.*?## "}; {printf "    \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Azure:"
	@grep -E '^azure-[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	    awk 'BEGIN {FS = ":.*?## "}; {printf "    \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Edit config.env to change cluster name, domain, worker count, etc."
	@echo ""

# ═══════════════════════════════════════════════════════════════════
#  Kind (local) targets
# ═══════════════════════════════════════════════════════════════════

prereqs: ## Install kind and kubectl if missing
	@echo "Checking prerequisites..."
	@command -v $(CONTAINER_CLI) >/dev/null || \
	    (echo "ERROR: $(CONTAINER_CLI) not found. Install it first." && exit 1)
	@command -v kind >/dev/null || \
	    (echo "Installing kind..." && brew install kind)
	@command -v kubectl >/dev/null || \
	    (echo "Installing kubectl..." && brew install kubectl)
	@echo "All prerequisites installed."
	@echo "  Container CLI: $(CONTAINER_CLI)"
	@echo "  kind:          $$(kind version 2>/dev/null)"
	@echo "  kubectl:       $$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"

cluster-up: prereqs ## Create the Kind cluster
	@chmod +x scripts/setup-kind.sh
	@./scripts/setup-kind.sh

deploy: ## Deploy CoreDNS static pods to all nodes
	@chmod +x scripts/deploy-coredns.sh
	@./scripts/deploy-coredns.sh

verify: ## Run DNS verification tests on all nodes
	@chmod +x scripts/verify-dns.sh
	@./scripts/verify-dns.sh

demo: cluster-up deploy verify ## Full demo: create cluster, deploy CoreDNS, verify

demo-failover: ## Simulate upstream DNS failure (cluster domains survive)
	@chmod +x scripts/demo-failover.sh
	@./scripts/demo-failover.sh

traffic: ## Start continuous DNS traffic generator (background)
	@chmod +x scripts/dns-traffic.sh
	@./scripts/dns-traffic.sh --background

traffic-stop: ## Stop the DNS traffic generator
	@PIDFILE="/tmp/dns-traffic-$(CLUSTER_NAME).pid"; \
	if [ -f "$$PIDFILE" ]; then \
		PID=$$(cat "$$PIDFILE"); \
		if kill -0 "$$PID" 2>/dev/null; then \
			kill "$$PID"; \
			echo "Traffic generator stopped (PID $$PID)."; \
		else \
			echo "Traffic generator not running (stale PID file)."; \
			rm -f "$$PIDFILE"; \
		fi; \
	else \
		echo "No traffic generator running (no PID file found)."; \
	fi

status: ## Show cluster and CoreDNS pod status
	@echo "Cluster: $(CLUSTER_NAME)"
	@echo ""
	@echo "Nodes:"
	@kubectl get nodes --context kind-$(CLUSTER_NAME) 2>/dev/null || echo "  Cluster not running"
	@echo ""
	@echo "CoreDNS Local Pods:"
	@kubectl get pods -n kube-system --context kind-$(CLUSTER_NAME) \
	    -l app=coredns-local -o wide 2>/dev/null || echo "  Not deployed"
	@echo ""
	@echo "All kube-system pods:"
	@kubectl get pods -n kube-system --context kind-$(CLUSTER_NAME) 2>/dev/null || true

clean: ## Delete the Kind cluster and generated files
	@kind delete cluster --name $(CLUSTER_NAME) 2>/dev/null || true
	@rm -f kind-config.yaml
	@echo "Cluster '$(CLUSTER_NAME)' deleted."

# ═══════════════════════════════════════════════════════════════════
#  Monitoring targets
# ═══════════════════════════════════════════════════════════════════

monitoring: ## Deploy Prometheus + Grafana monitoring stack
	@chmod +x scripts/deploy-monitoring.sh
	@./scripts/deploy-monitoring.sh

prometheus-ui: ## Open Prometheus UI (port-forward to localhost:9090)
	@echo "Prometheus available at http://localhost:9090"
	@echo "Press Ctrl+C to stop"
	@kubectl port-forward -n monitoring svc/prometheus 9090:9090 --context kind-$(CLUSTER_NAME)

grafana-ui: ## Open Grafana UI (port-forward to localhost:3000)
	@echo "Grafana available at http://localhost:3000"
	@echo "Press Ctrl+C to stop"
	@kubectl port-forward -n monitoring svc/grafana 3000:3000 --context kind-$(CLUSTER_NAME)

# ═══════════════════════════════════════════════════════════════════
#  Azure targets
# ═══════════════════════════════════════════════════════════════════

azure-infra: ## Create Azure infrastructure (VMs, VNet, NSG)
	@chmod +x azure/setup-azure.sh
	@./azure/setup-azure.sh

azure-cluster: ## Install k3s on Azure VMs
	@chmod +x azure/install-k3s.sh
	@./azure/install-k3s.sh

azure-deploy: ## Deploy CoreDNS static pods to Azure VMs
	@chmod +x azure/deploy-coredns-azure.sh
	@./azure/deploy-coredns-azure.sh

azure-verify: ## Run DNS verification tests on Azure VMs
	@chmod +x azure/verify-dns-azure.sh
	@./azure/verify-dns-azure.sh

azure-failover: ## Simulate upstream DNS failure on Azure
	@chmod +x azure/demo-failover-azure.sh
	@./azure/demo-failover-azure.sh

azure-demo: azure-infra azure-cluster azure-deploy azure-verify ## Full Azure demo lifecycle

azure-status: ## Show Azure cluster status
	@if [ -f azure/.env ]; then \
	    . azure/.env; \
	    echo "Cluster: $${CLUSTER_NAME}"; \
	    echo "Resource Group: $${RESOURCE_GROUP}"; \
	    echo ""; \
	    if [ -f azure/kubeconfig ]; then \
	        KUBECONFIG=azure/kubeconfig kubectl get nodes -o wide 2>/dev/null || echo "  Cannot reach cluster"; \
	        echo ""; \
	        KUBECONFIG=azure/kubeconfig kubectl get pods -n kube-system -l app=coredns-local -o wide 2>/dev/null || echo "  CoreDNS not deployed"; \
	    else \
	        echo "  No kubeconfig found. Run 'make azure-cluster' first."; \
	    fi; \
	else \
	    echo "  No Azure runtime state found. Run 'make azure-infra' first."; \
	fi

azure-clean: ## Destroy all Azure resources (double confirms)
	@chmod +x azure/teardown-azure.sh
	@./azure/teardown-azure.sh
