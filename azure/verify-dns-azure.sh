#!/usr/bin/env bash
# verify-dns-azure.sh — Verify custom DNS resolution on all Azure k3s nodes.
#
# Runs a suite of DNS tests on each VM via SSH to confirm:
#   - CoreDNS process is running
#   - Cluster-critical domains resolve locally
#   - External domains forward to upstream
#   - Prometheus metrics are available
#   - /etc/resolv.conf points to local CoreDNS
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

TOTAL_PASS=0
TOTAL_FAIL=0

header "Custom DNS Verification (Azure)"

echo "  Cluster: ${CLUSTER_NAME}"
echo "  Domain:  ${DOMAIN}"
echo ""

pass() {
    echo "  [PASS] $1"
    TOTAL_PASS=$((TOTAL_PASS + 1))
}

fail() {
    echo "  [FAIL] $1"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
}

# ── Build VM lists ──────────────────────────────────────────────────

ALL_VMS="${CP_VM} ${WORKER_VMS}"
ALL_PUBLIC="${CP_PUBLIC_IP} ${WORKER_PUBLIC_IPS}"
ALL_PRIVATE="${CP_PRIVATE_IP} ${WORKER_PRIVATE_IPS}"

# ── Run tests on each VM ────────────────────────────────────────────

VM_INDEX=1
for VM in $ALL_VMS; do
    PUB_IP=$(echo "$ALL_PUBLIC"  | awk "{print \$${VM_INDEX}}")
    PRIV_IP=$(echo "$ALL_PRIVATE" | awk "{print \$${VM_INDEX}}")

    echo "--- ${VM} (${PRIV_IP}) ---"

    # Ensure dig is available
    ssh_exec "$PUB_IP" "command -v dig >/dev/null 2>&1" 2>/dev/null || \
        ssh_exec "$PUB_IP" "sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y -qq dnsutils >/dev/null 2>&1" \
            2>/dev/null || true

    # ── Test 1: CoreDNS process is running ─────────────────────────
    COREDNS_PID=$(ssh_exec "$PUB_IP" "pgrep -f 'coredns.*Corefile'" 2>/dev/null || echo "")
    if [ -n "$COREDNS_PID" ]; then
        pass "CoreDNS process running (PID: ${COREDNS_PID})"
    else
        fail "CoreDNS process NOT running"
    fi

    # ── Test 2: api.<domain> resolves locally ──────────────────────
    RESULT=$(ssh_exec "$PUB_IP" "dig +short +timeout=3 api.${DOMAIN} @${PRIV_IP}" 2>/dev/null || echo "")
    if [ -n "$RESULT" ]; then
        pass "api.${DOMAIN} -> ${RESULT}"
    else
        fail "api.${DOMAIN} did not resolve"
    fi

    # ── Test 3: api-int.<domain> resolves locally ──────────────────
    RESULT=$(ssh_exec "$PUB_IP" "dig +short +timeout=3 api-int.${DOMAIN} @${PRIV_IP}" 2>/dev/null || echo "")
    if [ -n "$RESULT" ]; then
        pass "api-int.${DOMAIN} -> ${RESULT}"
    else
        fail "api-int.${DOMAIN} did not resolve"
    fi

    # ── Test 4: *.apps.<domain> resolves locally ───────────────────
    RESULT=$(ssh_exec "$PUB_IP" "dig +short +timeout=3 myapp.apps.${DOMAIN} @${PRIV_IP}" 2>/dev/null || echo "")
    if [ -n "$RESULT" ]; then
        pass "myapp.apps.${DOMAIN} -> ${RESULT}"
    else
        fail "myapp.apps.${DOMAIN} did not resolve"
    fi

    # ── Test 5: External domain forwards to upstream ───────────────
    RESULT=$(ssh_exec "$PUB_IP" "dig +short +timeout=5 google.com @${PRIV_IP}" 2>/dev/null || echo "")
    if [ -n "$RESULT" ]; then
        pass "google.com -> ${RESULT} (forwarded to upstream)"
    else
        fail "google.com did not resolve (upstream forwarding may be broken)"
    fi

    # ── Test 6: Prometheus metrics endpoint ────────────────────────
    METRICS=$(ssh_exec "$PUB_IP" \
        "curl -sf http://127.0.0.1:9153/metrics 2>/dev/null | grep -c coredns_dns_requests_total || echo 0" \
        2>/dev/null)
    if [ "$METRICS" -gt 0 ] 2>/dev/null; then
        pass "Prometheus metrics available at :9153/metrics (${METRICS} request counters)"
    else
        fail "Prometheus metrics not available at :9153"
    fi

    # ── Test 7: /etc/resolv.conf points to local CoreDNS ──────────
    NAMESERVER=$(ssh_exec "$PUB_IP" \
        "grep '^nameserver' /etc/resolv.conf | head -1 | awk '{print \$2}'" 2>/dev/null)
    if [ "$NAMESERVER" = "$PRIV_IP" ]; then
        pass "/etc/resolv.conf -> ${PRIV_IP} (local CoreDNS)"
    else
        echo "  [WARN] /etc/resolv.conf -> ${NAMESERVER} (expected ${PRIV_IP})"
    fi

    echo ""
    VM_INDEX=$((VM_INDEX + 1))
done

header "Verification Complete"

echo "  Passed: ${TOTAL_PASS}"
echo "  Failed: ${TOTAL_FAIL}"
echo ""

if [ "$TOTAL_FAIL" -gt 0 ]; then
    warn "Some tests failed. Check the output above."
    exit 1
fi
