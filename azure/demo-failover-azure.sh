#!/usr/bin/env bash
# demo-failover-azure.sh — Demonstrate that node-local DNS survives upstream DNS failure on Azure.
#
# This script:
#   1. Shows cluster domains AND external domains resolve (before)
#   2. Blocks Azure DNS (168.63.129.16) on all VMs via iptables
#   3. Shows cluster domains STILL resolve (self-hosted!)
#   4. Shows external domains FAIL (expected -- upstream is down)
#   5. Restores upstream DNS
#
# Reads config from config.env + azure/.env (runtime IPs).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${REPO_DIR}/scripts/common.sh"

load_project_config

ENVFILE="${SCRIPT_DIR}/.env"

# ── Load runtime state ────────────────────────────────────────────

if [ ! -f "$ENVFILE" ]; then
    error "azure/.env not found. Run 'make azure-infra' first."
fi

load_config "$ENVFILE"

header "DNS Failover Demo (Azure)"

ALL_VMS="${CP_VM} ${WORKER_VMS}"
ALL_PUBLIC="${CP_PUBLIC_IP} ${WORKER_PUBLIC_IPS}"

# Use control-plane as the demo node
DEMO_PUB="${CP_PUBLIC_IP}"
DEMO_PRIV="${CP_PRIVATE_IP}"

# Ensure dig is available
ssh_exec "$DEMO_PUB" "command -v dig >/dev/null 2>&1" 2>/dev/null || \
    ssh_exec "$DEMO_PUB" \
        "sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y -qq dnsutils >/dev/null 2>&1" \
        2>/dev/null || true

# Get the upstream DNS from the saved resolv.conf
UPSTREAM=$(ssh_exec "$DEMO_PUB" \
    "grep '^nameserver' /etc/resolv.conf.upstream 2>/dev/null | head -1 | awk '{print \$2}'" \
    2>/dev/null || echo "168.63.129.16")

echo "  Demo node:     ${CP_VM}"
echo "  Node IP:       ${DEMO_PRIV}"
echo "  Upstream DNS:  ${UPSTREAM}"
echo ""

# ── Phase 1: Before (everything works) ──────────────────────────────

echo "=== PHASE 1: Before failure (everything resolves) ==="
echo ""

RESULT=$(ssh_exec "$DEMO_PUB" "dig +short +timeout=3 api.${DOMAIN} @${DEMO_PRIV}" 2>/dev/null)
echo "  api.${DOMAIN}     -> ${RESULT:-FAIL}  (local CoreDNS)"

RESULT=$(ssh_exec "$DEMO_PUB" "dig +short +timeout=5 google.com @${DEMO_PRIV}" 2>/dev/null)
echo "  google.com            -> ${RESULT:-FAIL}  (forwarded to upstream)"

echo ""

# ── Phase 2: Break upstream DNS ──────────────────────────────────────

echo "=== PHASE 2: Simulating upstream DNS outage ==="
echo ""
echo "  Blocking upstream DNS (${UPSTREAM}) via iptables..."

VM_INDEX=1
for VM in $ALL_VMS; do
    PUB_IP=$(echo "$ALL_PUBLIC" | awk "{print \$${VM_INDEX}}")

    if echo "$UPSTREAM" | grep -q ':'; then
        IPTCMD="ip6tables"
    else
        IPTCMD="iptables"
    fi

    ssh_exec "$PUB_IP" "
        sudo ${IPTCMD} -A OUTPUT -d ${UPSTREAM} -p udp --dport 53 -j DROP 2>/dev/null || true
        sudo ${IPTCMD} -A OUTPUT -d ${UPSTREAM} -p tcp --dport 53 -j DROP 2>/dev/null || true
    "
    VM_INDEX=$((VM_INDEX + 1))
done

echo "  Upstream DNS blocked on all VMs."
echo ""

# ── Phase 3: After (cluster DNS survives, external fails) ───────────

echo "=== PHASE 3: After failure ==="
echo ""

RESULT=$(ssh_exec "$DEMO_PUB" "dig +short +timeout=3 api.${DOMAIN} @${DEMO_PRIV}" 2>/dev/null)
if [ -n "$RESULT" ]; then
    echo "  [SELF-HOSTED] api.${DOMAIN}        -> ${RESULT}  (STILL RESOLVES!)"
else
    echo "  [UNEXPECTED]  api.${DOMAIN}        -> FAILED"
fi

RESULT=$(ssh_exec "$DEMO_PUB" "dig +short +timeout=3 api-int.${DOMAIN} @${DEMO_PRIV}" 2>/dev/null)
if [ -n "$RESULT" ]; then
    echo "  [SELF-HOSTED] api-int.${DOMAIN}    -> ${RESULT}  (STILL RESOLVES!)"
else
    echo "  [UNEXPECTED]  api-int.${DOMAIN}    -> FAILED"
fi

RESULT=$(ssh_exec "$DEMO_PUB" "dig +short +timeout=3 myapp.apps.${DOMAIN} @${DEMO_PRIV}" 2>/dev/null)
if [ -n "$RESULT" ]; then
    echo "  [SELF-HOSTED] myapp.apps.${DOMAIN} -> ${RESULT}  (STILL RESOLVES!)"
else
    echo "  [UNEXPECTED]  myapp.apps.${DOMAIN} -> FAILED"
fi

# Use a unique external domain to avoid cached results from Phase 1
UNCACHED_DOMAIN="neverqueried-$(date +%s).example.com"
RESULT=$(ssh_exec "$DEMO_PUB" "dig +short +timeout=3 ${UNCACHED_DOMAIN} @${DEMO_PRIV}" 2>/dev/null)
if [ -n "$RESULT" ]; then
    echo "  [UNEXPECTED]  ${UNCACHED_DOMAIN} -> ${RESULT}  (should have failed)"
else
    echo "  [EXPECTED]    external domain       -> FAILED  (upstream is down)"
fi

echo ""

# ── Phase 4: Restore upstream DNS ────────────────────────────────────

echo "=== PHASE 4: Restoring upstream DNS ==="
echo ""

VM_INDEX=1
for VM in $ALL_VMS; do
    PUB_IP=$(echo "$ALL_PUBLIC" | awk "{print \$${VM_INDEX}}")

    if echo "$UPSTREAM" | grep -q ':'; then
        IPTCMD="ip6tables"
    else
        IPTCMD="iptables"
    fi

    ssh_exec "$PUB_IP" "
        sudo ${IPTCMD} -D OUTPUT -d ${UPSTREAM} -p udp --dport 53 -j DROP 2>/dev/null || true
        sudo ${IPTCMD} -D OUTPUT -d ${UPSTREAM} -p tcp --dport 53 -j DROP 2>/dev/null || true
    "
    VM_INDEX=$((VM_INDEX + 1))
done

echo "  Upstream DNS restored on all VMs."
echo ""

# Verify restoration
RESULT=$(ssh_exec "$DEMO_PUB" "dig +short +timeout=5 google.com @${DEMO_PRIV}" 2>/dev/null)
echo "  google.com -> ${RESULT:-still failing (cache may need to expire)}"

echo ""
header "Failover Demo Complete"

echo "  Key takeaway:"
echo "    Cluster-critical domains (api, api-int, *.apps) resolved throughout"
echo "    the upstream DNS outage. Azure DNS (${UPSTREAM}) was completely"
echo "    unreachable, but the cluster's own infrastructure DNS kept working."
echo ""
echo "    In a standard Azure setup, blocking 168.63.129.16 would break ALL"
echo "    DNS resolution, including the cluster's own API server."
echo ""
