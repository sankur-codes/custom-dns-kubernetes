#!/usr/bin/env bash
#
# deploy-coredns.sh — Deploy CoreDNS static pods to all nodes in a Kind cluster.
#
# This script:
#   1. Discovers all node containers for the given Kind cluster
#   2. Discovers the control-plane IP (API server) and first worker IP (Ingress)
#   3. Renders the Corefile template with actual IPs and domain
#   4. Copies the static pod manifest and Corefile into each node
#   5. Waits for CoreDNS to start on each node
#   6. Reconfigures each node's /etc/resolv.conf to use local CoreDNS
#
# Reads configuration from config.env. CLI args override if provided.
# Usage: ./deploy-coredns.sh [cluster-name] [container-cli]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/common.sh"

load_project_config

CLUSTER_NAME="${1:-${CLUSTER_NAME}}"
CLI="${2:-${CONTAINER_CLI}}"
MANIFEST="${REPO_DIR}/manifests/coredns-static-pod.yaml"
COREFILE_TEMPLATE="${REPO_DIR}/manifests/Corefile.template"

# Compute escaped domain for Corefile regex match
DOMAIN_REGEX=$(echo "$DOMAIN" | sed 's/\./\\\\./g')

header "Custom DNS Deployment"

echo "  Cluster:       ${CLUSTER_NAME}"
echo "  Container CLI: ${CLI}"
echo "  Domain:        ${DOMAIN}"
echo ""

# ── 1. Discover node containers ──────────────────────────────────────

NODES=$($CLI ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --format '{{.Names}}' 2>/dev/null | sort)

if [ -z "$NODES" ]; then
    error "No nodes found for cluster '${CLUSTER_NAME}'. Is the cluster running?"
fi

NODE_COUNT=$(echo "$NODES" | wc -l | tr -d ' ')
info "Discovered ${NODE_COUNT} node(s):"
echo "$NODES" | while read -r node; do echo "  - ${node}"; done
echo ""

# ── 2. Discover node IPs ────────────────────────────────────────────

# Control-plane IP serves as the "API server load balancer" IP
CP_NODE=$(echo "$NODES" | grep "control-plane" | head -1)
CP_IP=$($CLI inspect "$CP_NODE" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)

# First worker IP serves as the "Ingress load balancer" IP
WORKER_NODE=$(echo "$NODES" | grep -v "control-plane" | head -1 || true)
if [ -n "$WORKER_NODE" ]; then
    INGRESS_IP=$($CLI inspect "$WORKER_NODE" \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
else
    INGRESS_IP="$CP_IP"
fi

info "IP Assignments (simulating load balancers):"
echo "  API Server (api.${DOMAIN}):          ${CP_IP}"
echo "  API Internal (api-int.${DOMAIN}):    ${CP_IP}"
echo "  Ingress (*.apps.${DOMAIN}):          ${INGRESS_IP}"
echo ""

# ── 3. Deploy to each node ──────────────────────────────────────────

echo "$NODES" | while read -r NODE; do
    info "--- Deploying to ${NODE} ---"

    # Get this node's IP
    NODE_IP=$($CLI inspect "$NODE" \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)

    # Capture the original upstream DNS (use saved backup if available to avoid loop on re-deploy)
    UPSTREAM=$($CLI exec "$NODE" \
        sh -c "grep '^nameserver' /etc/resolv.conf.upstream 2>/dev/null | head -1 | awk '{print \$2}'" 2>/dev/null)
    if [ -z "$UPSTREAM" ]; then
        UPSTREAM=$($CLI exec "$NODE" \
            sh -c "grep '^nameserver' /etc/resolv.conf | head -1 | awk '{print \$2}'" 2>/dev/null)
    fi

    if [ -z "$UPSTREAM" ]; then
        UPSTREAM="8.8.8.8"
    fi

    echo "  Node IP:      ${NODE_IP}"
    echo "  Upstream DNS:  ${UPSTREAM}"

    # Create the CoreDNS config directory
    $CLI exec "$NODE" mkdir -p /etc/coredns

    # Render the Corefile from template
    TMPFILE=$(mktemp /tmp/Corefile-XXXXXX)
    sed -e "s|__API_IP__|${CP_IP}|g" \
        -e "s|__INGRESS_IP__|${INGRESS_IP}|g" \
        -e "s|__UPSTREAM_DNS__|${UPSTREAM}|g" \
        -e "s|__DOMAIN__|${DOMAIN}|g" \
        -e "s|__DOMAIN_REGEX__|${DOMAIN_REGEX}|g" \
        "$COREFILE_TEMPLATE" > "$TMPFILE"

    # Copy files into the node container
    $CLI cp "$TMPFILE" "${NODE}:/etc/coredns/Corefile"
    $CLI cp "$MANIFEST" "${NODE}:/etc/kubernetes/manifests/coredns-local.yaml"
    rm -f "$TMPFILE"

    # Fix permissions: podman/docker cp creates files as 600 (owner-only).
    # CoreDNS drops all capabilities and runs as non-root inside the container,
    # so the Corefile must be world-readable.
    $CLI exec "$NODE" chmod 644 /etc/coredns/Corefile
    $CLI exec "$NODE" chmod 644 /etc/kubernetes/manifests/coredns-local.yaml

    info "  Corefile and static pod manifest deployed."

    # Wait for CoreDNS to start listening on port 53
    info "  Waiting for CoreDNS to start..."
    STARTED=false
    for i in $(seq 1 45); do
        if $CLI exec "$NODE" sh -c \
            "ss -ulnp 2>/dev/null | grep -q ':53 ' || netstat -ulnp 2>/dev/null | grep -q ':53 '" \
            2>/dev/null; then
            STARTED=true
            break
        fi
        sleep 1
    done

    if [ "$STARTED" = true ]; then
        success "  CoreDNS is listening on port 53."
    else
        warn "  CoreDNS may not be ready yet. Check: kubectl get pods -n kube-system | grep coredns-local"
    fi

    # Save original resolv.conf and reconfigure DNS to use local CoreDNS
    $CLI exec "$NODE" sh -c "
        cp /etc/resolv.conf /etc/resolv.conf.upstream 2>/dev/null || true
        cat > /etc/resolv.conf <<RESOLV
nameserver ${NODE_IP}
nameserver ${UPSTREAM}
search ${DOMAIN}
RESOLV
    "
    info "  /etc/resolv.conf updated: nameserver ${NODE_IP} (local CoreDNS)"
    echo ""
done

header "Deployment Complete"

echo "  CoreDNS static pods deployed to all ${NODE_COUNT} node(s)."
echo ""
echo "  Domains resolved locally (no external DNS):"
echo "    api.${DOMAIN}         -> ${CP_IP}"
echo "    api-int.${DOMAIN}     -> ${CP_IP}"
echo "    *.apps.${DOMAIN}      -> ${INGRESS_IP}"
echo ""
echo "  Next step:  make verify"
echo ""
