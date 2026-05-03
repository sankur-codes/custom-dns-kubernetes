#!/usr/bin/env bash
# setup-kind.sh — Set up the Kind cluster from config.env.
#
# Reads cluster name and worker count from config.env.
# Generates kind-config.yaml and creates the cluster.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/common.sh"

load_project_config

export KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_CLI}"

header "Kind Cluster Setup"

info "Configuration (from config.env):"
echo "  Cluster name:  ${CLUSTER_NAME}"
echo "  Domain:        ${DOMAIN}"
echo "  Workers:       ${WORKER_COUNT}"
echo "  Container CLI: ${CONTAINER_CLI}"
TOTAL_NODES=$((WORKER_COUNT + 1))
echo "  Total nodes:   ${TOTAL_NODES} (1 control-plane + ${WORKER_COUNT} workers)"
echo ""

# ── Generate kind-config.yaml ───────────────────────────────────────

KIND_CONFIG="${REPO_DIR}/kind-config.yaml"

info "Generating ${KIND_CONFIG}..."

cat > "$KIND_CONFIG" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
- role: control-plane
EOF

for i in $(seq 1 "$WORKER_COUNT"); do
    echo "- role: worker" >> "$KIND_CONFIG"
done

success "kind-config.yaml generated (1 control-plane + ${WORKER_COUNT} workers)."

# ── Check for existing cluster ──────────────────────────────────────

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    warn "Cluster '${CLUSTER_NAME}' already exists."
    if confirm "Delete and recreate it?"; then
        info "Deleting existing cluster..."
        kind delete cluster --name "$CLUSTER_NAME"
    else
        success "Keeping existing cluster."
        exit 0
    fi
fi

# ── Create the cluster ──────────────────────────────────────────────

info "Creating Kind cluster '${CLUSTER_NAME}'..."
kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"

echo ""
kubectl cluster-info --context "kind-${CLUSTER_NAME}" 2>/dev/null || true
echo ""
kubectl get nodes --context "kind-${CLUSTER_NAME}" 2>/dev/null || true

success "Kind cluster '${CLUSTER_NAME}' is ready."
