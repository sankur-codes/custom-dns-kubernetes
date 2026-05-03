#!/usr/bin/env bash
#
# verify-dns.sh — Verify custom DNS resolution on all Kind cluster nodes.
#
# Runs a suite of DNS tests on each node to confirm:
#   - CoreDNS static pod is running
#   - Cluster-critical domains resolve locally
#   - External domains forward to upstream
#   - Prometheus metrics are available
#   - /etc/resolv.conf points to local CoreDNS
#
# Reads configuration from config.env. CLI args override if provided.
# Usage: ./verify-dns.sh [cluster-name] [container-cli]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/common.sh"

load_project_config

CLUSTER_NAME="${1:-${CLUSTER_NAME}}"
CLI="${2:-${CONTAINER_CLI}}"

TOTAL_PASS=0
TOTAL_FAIL=0

header "Custom DNS Verification"

echo "  Cluster: ${CLUSTER_NAME}"
echo "  Domain:  ${DOMAIN}"
echo ""

NODES=$($CLI ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --format '{{.Names}}' 2>/dev/null | sort)

if [ -z "$NODES" ]; then
    error "No nodes found for cluster '${CLUSTER_NAME}'."
fi

pass() {
    echo "  [PASS] $1"
    TOTAL_PASS=$((TOTAL_PASS + 1))
}

fail() {
    echo "  [FAIL] $1"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
}

echo "$NODES" | while read -r NODE; do
    echo "--- ${NODE} ---"

    NODE_IP=$($CLI inspect "$NODE" \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)

    # ── Test 0: Install dig if not present ─────────────────────────
    $CLI exec "$NODE" sh -c "command -v dig >/dev/null 2>&1" 2>/dev/null || \
        $CLI exec "$NODE" sh -c \
            "apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq dnsutils >/dev/null 2>&1" \
            2>/dev/null || true

    # ── Test 1: CoreDNS process is running ─────────────────────────
    COREDNS_PID=$($CLI exec "$NODE" sh -c "pgrep -f 'coredns.*Corefile'" 2>/dev/null || echo "")
    if [ -n "$COREDNS_PID" ]; then
        pass "CoreDNS process running (PID: ${COREDNS_PID})"
    else
        fail "CoreDNS process NOT running"
    fi

    # ── Test 2: api.<domain> resolves locally ──────────────────────
    RESULT=$($CLI exec "$NODE" dig +short +timeout=3 "api.${DOMAIN}" "@${NODE_IP}" 2>/dev/null || echo "")
    if [ -n "$RESULT" ]; then
        pass "api.${DOMAIN} -> ${RESULT}"
    else
        fail "api.${DOMAIN} did not resolve"
    fi

    # ── Test 3: api-int.<domain> resolves locally ──────────────────
    RESULT=$($CLI exec "$NODE" dig +short +timeout=3 "api-int.${DOMAIN}" "@${NODE_IP}" 2>/dev/null || echo "")
    if [ -n "$RESULT" ]; then
        pass "api-int.${DOMAIN} -> ${RESULT}"
    else
        fail "api-int.${DOMAIN} did not resolve"
    fi

    # ── Test 4: *.apps.<domain> resolves locally ───────────────────
    RESULT=$($CLI exec "$NODE" dig +short +timeout=3 "myapp.apps.${DOMAIN}" "@${NODE_IP}" 2>/dev/null || echo "")
    if [ -n "$RESULT" ]; then
        pass "myapp.apps.${DOMAIN} -> ${RESULT}"
    else
        fail "myapp.apps.${DOMAIN} did not resolve"
    fi

    # ── Test 5: External domain forwards to upstream ───────────────
    RESULT=$($CLI exec "$NODE" dig +short +timeout=5 "google.com" "@${NODE_IP}" 2>/dev/null || echo "")
    if [ -n "$RESULT" ]; then
        pass "google.com -> ${RESULT} (forwarded to upstream)"
    else
        fail "google.com did not resolve (upstream forwarding may be broken)"
    fi

    # ── Test 6: Prometheus metrics endpoint ────────────────────────
    METRICS=$($CLI exec "$NODE" sh -c \
        "curl -sf http://127.0.0.1:9153/metrics 2>/dev/null | grep -c coredns_dns_requests_total || echo 0" \
        2>/dev/null)
    if [ "$METRICS" -gt 0 ] 2>/dev/null; then
        pass "Prometheus metrics available at :9153/metrics (${METRICS} request counters)"
    else
        fail "Prometheus metrics not available at :9153"
    fi

    # ── Test 7: /etc/resolv.conf points to local CoreDNS ──────────
    NAMESERVER=$($CLI exec "$NODE" sh -c \
        "grep '^nameserver' /etc/resolv.conf | head -1 | awk '{print \$2}'" 2>/dev/null)
    if [ "$NAMESERVER" = "$NODE_IP" ]; then
        pass "/etc/resolv.conf -> ${NODE_IP} (local CoreDNS)"
    else
        warn "/etc/resolv.conf -> ${NAMESERVER} (expected ${NODE_IP})"
    fi

    echo ""
done

header "Verification Complete"

echo "  Passed: ${TOTAL_PASS}"
echo "  Failed: ${TOTAL_FAIL}"
echo ""
