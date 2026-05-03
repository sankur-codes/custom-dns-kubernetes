#!/usr/bin/env bash
#
# demo-failover.sh — Demonstrate that node-local DNS survives upstream DNS failure.
#
# This script:
#   1. Shows that cluster domains AND external domains resolve (before)
#   2. Blocks upstream DNS on all nodes (simulates cloud DNS outage)
#   3. Shows that cluster domains STILL resolve (self-hosted!)
#   4. Shows that external domains FAIL (expected -- upstream is down)
#   5. Restores upstream DNS
#
# Reads configuration from config.env. CLI args override if provided.
# Usage: ./demo-failover.sh [cluster-name] [container-cli]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/common.sh"

load_project_config

CLUSTER_NAME="${1:-${CLUSTER_NAME}}"
CLI="${2:-${CONTAINER_CLI}}"

header "DNS Failover Demo"

NODES=$($CLI ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --format '{{.Names}}' 2>/dev/null | sort)

if [ -z "$NODES" ]; then
    error "No nodes found for cluster '${CLUSTER_NAME}'."
fi

# Pick one node for the demo (control-plane)
DEMO_NODE=$(echo "$NODES" | grep "control-plane" | head -1)
DEMO_IP=$($CLI inspect "$DEMO_NODE" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)

# Install dig if needed
$CLI exec "$DEMO_NODE" sh -c "command -v dig >/dev/null 2>&1" 2>/dev/null || \
    $CLI exec "$DEMO_NODE" sh -c \
        "apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq dnsutils >/dev/null 2>&1" \
        2>/dev/null || true

# Get the upstream DNS from the saved resolv.conf
UPSTREAM=$($CLI exec "$DEMO_NODE" sh -c \
    "grep '^nameserver' /etc/resolv.conf.upstream 2>/dev/null | head -1 | awk '{print \$2}'" \
    2>/dev/null || echo "8.8.8.8")

echo "Demo node:     ${DEMO_NODE}"
echo "Node IP:       ${DEMO_IP}"
echo "Upstream DNS:  ${UPSTREAM}"
echo ""

# ── Phase 1: Before (everything works) ──────────────────────────────
echo "=== PHASE 1: Before failure (everything resolves) ==="
echo ""

RESULT=$($CLI exec "$DEMO_NODE" dig +short +timeout=3 "api.${DOMAIN}" "@${DEMO_IP}" 2>/dev/null)
echo "  api.${DOMAIN}     -> ${RESULT:-FAIL}  (local CoreDNS)"

RESULT=$($CLI exec "$DEMO_NODE" dig +short +timeout=5 "google.com" "@${DEMO_IP}" 2>/dev/null)
echo "  google.com            -> ${RESULT:-FAIL}  (forwarded to upstream)"

echo ""

# ── Phase 2: Break upstream DNS ──────────────────────────────────────
echo "=== PHASE 2: Simulating upstream DNS outage ==="
echo ""
echo "  Blocking upstream DNS (${UPSTREAM}) via iptables..."

echo "$NODES" | while read -r NODE; do
    if echo "$UPSTREAM" | grep -q ':'; then
        IPTCMD="ip6tables"
    else
        IPTCMD="iptables"
    fi
    $CLI exec "$NODE" sh -c "
        ${IPTCMD} -A OUTPUT -d ${UPSTREAM} -p udp --dport 53 -j DROP 2>/dev/null || true
        ${IPTCMD} -A OUTPUT -d ${UPSTREAM} -p tcp --dport 53 -j DROP 2>/dev/null || true
    " 2>/dev/null
done

echo "  Upstream DNS blocked on all nodes."
echo ""

# ── Phase 3: After (cluster DNS survives, external fails) ───────────
echo "=== PHASE 3: After failure ==="
echo ""

RESULT=$($CLI exec "$DEMO_NODE" dig +short +timeout=3 "api.${DOMAIN}" "@${DEMO_IP}" 2>/dev/null)
if [ -n "$RESULT" ]; then
    echo "  [SELF-HOSTED] api.${DOMAIN}        -> ${RESULT}  (STILL RESOLVES!)"
else
    echo "  [UNEXPECTED]  api.${DOMAIN}        -> FAILED"
fi

RESULT=$($CLI exec "$DEMO_NODE" dig +short +timeout=3 "api-int.${DOMAIN}" "@${DEMO_IP}" 2>/dev/null)
if [ -n "$RESULT" ]; then
    echo "  [SELF-HOSTED] api-int.${DOMAIN}    -> ${RESULT}  (STILL RESOLVES!)"
else
    echo "  [UNEXPECTED]  api-int.${DOMAIN}    -> FAILED"
fi

RESULT=$($CLI exec "$DEMO_NODE" dig +short +timeout=3 "myapp.apps.${DOMAIN}" "@${DEMO_IP}" 2>/dev/null)
if [ -n "$RESULT" ]; then
    echo "  [SELF-HOSTED] myapp.apps.${DOMAIN} -> ${RESULT}  (STILL RESOLVES!)"
else
    echo "  [UNEXPECTED]  myapp.apps.${DOMAIN} -> FAILED"
fi

# Use a unique external domain to avoid cached results from Phase 1
UNCACHED_DOMAIN="neverqueried-$(date +%s).example.com"
RESULT=$($CLI exec "$DEMO_NODE" dig +short +timeout=3 "${UNCACHED_DOMAIN}" "@${DEMO_IP}" 2>/dev/null)
if [ -n "$RESULT" ]; then
    echo "  [UNEXPECTED]  ${UNCACHED_DOMAIN} -> ${RESULT}  (should have failed)"
else
    echo "  [EXPECTED]    external domain       -> FAILED  (upstream is down)"
fi

echo ""

# ── Phase 4: Restore upstream DNS ────────────────────────────────────
echo "=== PHASE 4: Restoring upstream DNS ==="
echo ""

echo "$NODES" | while read -r NODE; do
    if echo "$UPSTREAM" | grep -q ':'; then
        IPTCMD="ip6tables"
    else
        IPTCMD="iptables"
    fi
    $CLI exec "$NODE" sh -c "
        ${IPTCMD} -D OUTPUT -d ${UPSTREAM} -p udp --dport 53 -j DROP 2>/dev/null || true
        ${IPTCMD} -D OUTPUT -d ${UPSTREAM} -p tcp --dport 53 -j DROP 2>/dev/null || true
    " 2>/dev/null
done

echo "  Upstream DNS restored on all nodes."
echo ""

# Verify restoration
RESULT=$($CLI exec "$DEMO_NODE" dig +short +timeout=5 "google.com" "@${DEMO_IP}" 2>/dev/null)
echo "  google.com -> ${RESULT:-still failing (cache may need to expire)}"

echo ""
header "Failover Demo Complete"

echo "  Key takeaway:"
echo "    Cluster-critical domains (api, api-int, *.apps) resolved throughout"
echo "    the upstream DNS outage. The cluster is DNS-self-sufficient for its"
echo "    own infrastructure domains."
echo ""
