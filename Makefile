# ── Configuration ──────────────────────────────────────────────────
# All config comes from config.env. Edit that file to change defaults.

include config.env

# Kind needs this env var when using Podman
export KIND_EXPERIMENTAL_PROVIDER := $(CONTAINER_CLI)

.PHONY: help prereqs cluster-up deploy verify demo demo-failover walkthrough status clean \
        traffic traffic-stop \
        demo-apps demo-apps-clean dns-test \
        monitoring prometheus-ui grafana-ui port-forward port-forward-stop \
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

demo: cluster-up deploy verify demo-apps dns-test monitoring port-forward ## Full demo: cluster, CoreDNS, apps, monitoring, dashboards

walkthrough: ## Interactive feature walkthrough (run after 'make demo')
	@chmod +x scripts/walkthrough.sh
	@./scripts/walkthrough.sh

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

clean: port-forward-stop ## Delete the Kind cluster and generated files
	@kind delete cluster --name $(CLUSTER_NAME) 2>/dev/null || true
	@rm -f kind-config.yaml
	@echo "Cluster '$(CLUSTER_NAME)' deleted."

demo-apps: ## Deploy demo application services (web, api, cache, db)
	@chmod +x scripts/deploy-demo-apps.sh
	@./scripts/deploy-demo-apps.sh

demo-apps-clean: ## Remove demo application services
	@kubectl delete namespace demo-apps --context kind-$(CLUSTER_NAME) 2>/dev/null && \
		echo "Demo apps namespace deleted." || \
		echo "Demo apps namespace not found."

dns-test: ## Create a DNS test pod for interactive queries
	@kubectl run dns-test --image=busybox:1.36 --restart=Never \
		--context kind-$(CLUSTER_NAME) -- sleep 86400 2>/dev/null || true
	@kubectl wait --for=condition=Ready pod/dns-test \
		--context kind-$(CLUSTER_NAME) --timeout=30s 2>/dev/null
	@echo "dns-test pod ready."

# ═══════════════════════════════════════════════════════════════════
#  Monitoring targets
# ═══════════════════════════════════════════════════════════════════

monitoring: ## Deploy Prometheus + Grafana monitoring stack
	@chmod +x scripts/deploy-monitoring.sh
	@./scripts/deploy-monitoring.sh

prometheus-ui: ## Open Prometheus UI (foreground, port-forward)
	@echo "Prometheus available at http://localhost:$(PROMETHEUS_PORT)"
	@echo "Press Ctrl+C to stop"
	@kubectl port-forward -n monitoring svc/prometheus $(PROMETHEUS_PORT):9090 --context kind-$(CLUSTER_NAME)

grafana-ui: ## Open Grafana UI (foreground, port-forward)
	@echo "Grafana available at http://localhost:$(GRAFANA_PORT)"
	@echo "Press Ctrl+C to stop"
	@kubectl port-forward -n monitoring svc/grafana $(GRAFANA_PORT):3000 --context kind-$(CLUSTER_NAME)

port-forward: ## Start Prometheus + Grafana port-forwards in background
	@echo "Waiting for monitoring pods to be ready..."
	@kubectl wait --for=condition=Ready pod -l app=prometheus -n monitoring \
		--context kind-$(CLUSTER_NAME) --timeout=120s 2>/dev/null || true
	@kubectl wait --for=condition=Ready pod -l app=grafana -n monitoring \
		--context kind-$(CLUSTER_NAME) --timeout=120s 2>/dev/null || true
	@for PF in prometheus grafana; do \
		PIDFILE="/tmp/$${PF}-pf-$(CLUSTER_NAME).pid"; \
		if [ -f "$$PIDFILE" ] && kill -0 $$(cat "$$PIDFILE") 2>/dev/null; then \
			echo "$$PF port-forward already running (PID $$(cat $$PIDFILE))."; \
		else \
			rm -f "$$PIDFILE"; \
			if [ "$$PF" = "prometheus" ]; then \
				kubectl port-forward -n monitoring svc/prometheus $(PROMETHEUS_PORT):9090 --context kind-$(CLUSTER_NAME) &>/dev/null & \
			else \
				kubectl port-forward -n monitoring svc/grafana $(GRAFANA_PORT):3000 --context kind-$(CLUSTER_NAME) &>/dev/null & \
			fi; \
			echo $$! > "$$PIDFILE"; \
		fi; \
	done
	@echo ""
	@echo "  Prometheus:  http://localhost:$(PROMETHEUS_PORT)"
	@echo "  Grafana:     http://localhost:$(GRAFANA_PORT)"
	@echo ""
	@echo "  Stop with: make port-forward-stop"

port-forward-stop: ## Stop background port-forwards
	@for PF in prometheus grafana; do \
		PIDFILE="/tmp/$${PF}-pf-$(CLUSTER_NAME).pid"; \
		if [ -f "$$PIDFILE" ]; then \
			PID=$$(cat "$$PIDFILE"); \
			if kill -0 "$$PID" 2>/dev/null; then \
				kill "$$PID"; \
				echo "$$PF port-forward stopped (PID $$PID)."; \
			fi; \
			rm -f "$$PIDFILE"; \
		fi; \
	done

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
