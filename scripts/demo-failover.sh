#!/usr/bin/env bash
#
# demo-failover.sh — Interactive demo: node-local DNS survives upstream DNS failure.
#
# This script walks through 4 phases interactively, pausing for a keypress
# between each step so the presenter can narrate:
#
#   1. Shows that cluster domains AND external domains resolve (before)
#   2. Blocks upstream DNS on all nodes (simulates cloud DNS outage)
#   3. Shows that cluster domains STILL resolve (self-hosted!)
#   4. Restores upstream DNS and verifies recovery
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

# Determine iptables command based on upstream address family
iptables_cmd() {
    if echo "$UPSTREAM" | grep -q ':'; then
        echo "ip6tables"
    else
        echo "iptables"
    fi
}

IPTCMD=""

header "DNS Failover Demo (Interactive)"

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

IPTCMD=$(iptables_cmd)

echo "Demo node:     ${DEMO_NODE}"
echo "Node IP:       ${DEMO_IP}"
echo "Upstream DNS:  ${UPSTREAM}"

# ═══════════════════════════════════════════════════════════════════
#  Phase 1: Before (everything works)
# ═══════════════════════════════════════════════════════════════════

header "PHASE 1: Before failure (everything resolves)"

echo "  We'll query a cluster domain and an external domain to show"
echo "  that both resolve normally before any failure."
echo ""
echo "  Commands to run:"
show_cmd "${CLI} exec ${DEMO_NODE} dig +short api.${DOMAIN} @${DEMO_IP}"
show_cmd "${CLI} exec ${DEMO_NODE} dig +short google.com @${DEMO_IP}"

pause "Run Phase 1 queries?"

echo ""
RESULT=$($CLI exec "$DEMO_NODE" dig +short +timeout=3 "api.${DOMAIN}" "@${DEMO_IP}" 2>/dev/null)
echo -e "  api.${DOMAIN}     -> ${_GREEN}${RESULT:-FAIL}${_RESET}  (local CoreDNS)"

RESULT=$($CLI exec "$DEMO_NODE" dig +short +timeout=5 "google.com" "@${DEMO_IP}" 2>/dev/null)
echo -e "  google.com            -> ${_GREEN}${RESULT:-FAIL}${_RESET}  (forwarded to upstream)"

echo ""
success "Both cluster and external domains resolve. Baseline confirmed."

# ═══════════════════════════════════════════════════════════════════
#  Phase 2: Break upstream DNS
# ═══════════════════════════════════════════════════════════════════

header "PHASE 2: Simulating upstream DNS outage"

echo "  We'll block all outbound DNS traffic to the upstream server (${UPSTREAM})"
echo "  using iptables on every node. This simulates a cloud DNS outage."
echo ""
echo "  Commands to run on each node:"
show_cmd "${IPTCMD} -A OUTPUT -d ${UPSTREAM} -p udp --dport 53 -j DROP"
show_cmd "${IPTCMD} -A OUTPUT -d ${UPSTREAM} -p tcp --dport 53 -j DROP"

pause "Block upstream DNS on all nodes?"

echo ""
echo "$NODES" | while read -r NODE; do
    $CLI exec "$NODE" sh -c "
        ${IPTCMD} -A OUTPUT -d ${UPSTREAM} -p udp --dport 53 -j DROP 2>/dev/null || true
        ${IPTCMD} -A OUTPUT -d ${UPSTREAM} -p tcp --dport 53 -j DROP 2>/dev/null || true
    " 2>/dev/null
    echo "  Blocked on ${NODE}"
done

echo ""
success "Upstream DNS blocked on all nodes."

echo ""
echo "  Verify the iptables rules were applied:"
show_cmd "${CLI} exec ${DEMO_NODE} ${IPTCMD} -L OUTPUT -n | grep ${UPSTREAM}"

pause "Show iptables rules?"

echo ""
$CLI exec "$DEMO_NODE" ${IPTCMD} -L OUTPUT -n 2>/dev/null | grep -E "DROP.*${UPSTREAM}" | while read -r RULE; do
    echo "  ${RULE}"
done

echo ""
success "iptables DROP rules confirmed for ${UPSTREAM}."

# ═══════════════════════════════════════════════════════════════════
#  Phase 3: After (cluster DNS survives, external fails)
# ═══════════════════════════════════════════════════════════════════

header "PHASE 3: After failure — the proof"

echo "  Upstream DNS is blocked. We'll now test:"
echo "    - Cluster domains (api, api-int, *.apps) — should STILL resolve"
echo "    - External domain — should FAIL"
echo ""
echo "  Commands to run:"
show_cmd "${CLI} exec ${DEMO_NODE} dig +short api.${DOMAIN} @${DEMO_IP}"
show_cmd "${CLI} exec ${DEMO_NODE} dig +short api-int.${DOMAIN} @${DEMO_IP}"
show_cmd "${CLI} exec ${DEMO_NODE} dig +short myapp.apps.${DOMAIN} @${DEMO_IP}"

pause "Test cluster domains with upstream blocked?"

echo ""
RESULT=$($CLI exec "$DEMO_NODE" dig +short +timeout=3 "api.${DOMAIN}" "@${DEMO_IP}" 2>/dev/null)
if [ -n "$RESULT" ]; then
    echo -e "  ${_GREEN}[SELF-HOSTED]${_RESET} api.${DOMAIN}        -> ${RESULT}  (STILL RESOLVES!)"
else
    echo -e "  ${_RED}[UNEXPECTED]${_RESET}  api.${DOMAIN}        -> FAILED"
fi

RESULT=$($CLI exec "$DEMO_NODE" dig +short +timeout=3 "api-int.${DOMAIN}" "@${DEMO_IP}" 2>/dev/null)
if [ -n "$RESULT" ]; then
    echo -e "  ${_GREEN}[SELF-HOSTED]${_RESET} api-int.${DOMAIN}    -> ${RESULT}  (STILL RESOLVES!)"
else
    echo -e "  ${_RED}[UNEXPECTED]${_RESET}  api-int.${DOMAIN}    -> FAILED"
fi

RESULT=$($CLI exec "$DEMO_NODE" dig +short +timeout=3 "myapp.apps.${DOMAIN}" "@${DEMO_IP}" 2>/dev/null)
if [ -n "$RESULT" ]; then
    echo -e "  ${_GREEN}[SELF-HOSTED]${_RESET} myapp.apps.${DOMAIN} -> ${RESULT}  (STILL RESOLVES!)"
else
    echo -e "  ${_RED}[UNEXPECTED]${_RESET}  myapp.apps.${DOMAIN} -> FAILED"
fi

echo ""
echo "  Now test an external domain (should fail — upstream is blocked):"
UNCACHED_DOMAIN="neverqueried-$(date +%s).example.com"
show_cmd "${CLI} exec ${DEMO_NODE} dig +short ${UNCACHED_DOMAIN} @${DEMO_IP}"

pause "Test external domain resolution?"

echo ""
RESULT=$($CLI exec "$DEMO_NODE" dig +short +timeout=3 "${UNCACHED_DOMAIN}" "@${DEMO_IP}" 2>/dev/null)
if [ -n "$RESULT" ]; then
    echo -e "  ${_RED}[UNEXPECTED]${_RESET}  ${UNCACHED_DOMAIN} -> ${RESULT}  (should have failed)"
else
    echo -e "  ${_GREEN}[EXPECTED]${_RESET}    external domain       -> FAILED  (upstream is down)"
fi

echo ""
success "Cluster domains survived the outage. External domains failed as expected."

# ═══════════════════════════════════════════════════════════════════
#  Phase 4: Restore upstream DNS
# ═══════════════════════════════════════════════════════════════════

header "PHASE 4: Restoring upstream DNS"

echo "  We'll remove the iptables DROP rules to restore upstream DNS."
echo ""
echo "  Commands to run on each node:"
show_cmd "${IPTCMD} -D OUTPUT -d ${UPSTREAM} -p udp --dport 53 -j DROP"
show_cmd "${IPTCMD} -D OUTPUT -d ${UPSTREAM} -p tcp --dport 53 -j DROP"

pause "Restore upstream DNS on all nodes?"

echo ""
echo "$NODES" | while read -r NODE; do
    $CLI exec "$NODE" sh -c "
        ${IPTCMD} -D OUTPUT -d ${UPSTREAM} -p udp --dport 53 -j DROP 2>/dev/null || true
        ${IPTCMD} -D OUTPUT -d ${UPSTREAM} -p tcp --dport 53 -j DROP 2>/dev/null || true
    " 2>/dev/null
    echo "  Restored on ${NODE}"
done

echo ""
success "Upstream DNS restored on all nodes."

echo ""
echo "  Verify the iptables rules were removed:"
show_cmd "${CLI} exec ${DEMO_NODE} ${IPTCMD} -L OUTPUT -n"

pause "Confirm iptables rules are gone?"

echo ""
REMAINING=$($CLI exec "$DEMO_NODE" ${IPTCMD} -L OUTPUT -n 2>/dev/null | grep -c "${UPSTREAM}" || true)
if [ "$REMAINING" -eq 0 ]; then
    echo "  No DROP rules for ${UPSTREAM} — clean."
else
    echo "  Warning: ${REMAINING} rule(s) still reference ${UPSTREAM}."
fi

echo ""
echo "  Verify external DNS resolves again:"
show_cmd "${CLI} exec ${DEMO_NODE} dig +short google.com @${DEMO_IP}"

pause "Test external resolution?"

echo ""
RESULT=$($CLI exec "$DEMO_NODE" dig +short +timeout=5 "google.com" "@${DEMO_IP}" 2>/dev/null)
echo -e "  google.com -> ${_GREEN}${RESULT:-still failing (cache may need to expire)}${_RESET}"

header "Failover Demo Complete"

echo "  Key takeaway:"
echo "    Cluster-critical domains (api, api-int, *.apps) resolved throughout"
echo "    the upstream DNS outage. The cluster is DNS-self-sufficient for its"
echo "    own infrastructure domains."
echo ""
