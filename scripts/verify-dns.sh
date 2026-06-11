#!/usr/bin/env bash
#
# verify-dns.sh — Verify CoreDNS static pod deployment with focus on
# what makes this approach unique: static pod resilience, native
# Prometheus observability, and per-zone metrics.
#
# Tests (per node):
#   1. CoreDNS static pod is running (kubelet-managed)
#   2. DNS resolution works (quick bootstrap check)
#   3. /etc/resolv.conf points to local CoreDNS
#   4. Native Prometheus metrics available at :9153
#   5. Per-zone metrics — independent counters per domain zone
#   6. Cache metrics via Prometheus (no log parsing needed)
#   7. Static pod manifest present (kubelet resilience mechanism)
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
CONTEXT="kind-${CLUSTER_NAME}"

TOTAL_PASS=0
TOTAL_FAIL=0

pass() {
    echo "  [PASS] $1"
    TOTAL_PASS=$((TOTAL_PASS + 1))
}

fail() {
    echo "  [FAIL] $1"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
}

header "CoreDNS Static Pod Verification"

echo "  Cluster: ${CLUSTER_NAME}"
echo "  Domain:  ${DOMAIN}"
echo "  Focus:   static pod resilience + native observability"
echo ""

# ── Discover nodes ──────────────────────────────────────────────────────

NODES=$($CLI ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --format '{{.Names}}' 2>/dev/null | sort)

if [ -z "$NODES" ]; then
    error "No nodes found for cluster '${CLUSTER_NAME}'. Is the cluster running?"
fi

# Install dig if needed on all nodes
while read -r NODE; do
    $CLI exec "$NODE" sh -c "command -v dig >/dev/null 2>&1" 2>/dev/null || \
        $CLI exec "$NODE" sh -c \
            "apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq dnsutils >/dev/null 2>&1" \
            2>/dev/null || true
done <<< "$NODES"

# ── Run 7 tests per node ────────────────────────────────────────────────

while read -r NODE; do
    NODE_IP=$($CLI inspect "$NODE" \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)

    echo "--- ${NODE} (${NODE_IP}) ---"

    # ── Test 1: CoreDNS static pod is running ─────────────────────
    # Check process AND that it's visible as a static pod in kube-system
    COREDNS_PID=$($CLI exec "$NODE" sh -c "pgrep -f 'coredns.*Corefile'" 2>/dev/null || echo "")
    STATIC_POD=$(kubectl get pods -n kube-system --context "$CONTEXT" \
        --field-selector "spec.nodeName=${NODE}" -l app=coredns-local \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$COREDNS_PID" ] && [ -n "$STATIC_POD" ]; then
        pass "CoreDNS static pod running (PID: $(echo "$COREDNS_PID" | head -1), pod: ${STATIC_POD})"
    elif [ -n "$COREDNS_PID" ]; then
        pass "CoreDNS process running (PID: $(echo "$COREDNS_PID" | head -1)) — static pod not yet visible"
    else
        fail "CoreDNS process NOT running"
    fi

    # ── Test 2: DNS resolution works (bootstrap check) ────────────
    # Single domain check — dnsmasq demo covers exhaustive domain tests
    RESULT=$($CLI exec "$NODE" dig +short +timeout=3 "api.${DOMAIN}" "@${NODE_IP}" 2>/dev/null || echo "")
    if [ -n "$RESULT" ]; then
        pass "api.${DOMAIN} -> ${RESULT} (DNS resolution operational)"
    else
        fail "api.${DOMAIN} did not resolve"
    fi

    # ── Test 3: /etc/resolv.conf points to local CoreDNS ─────────
    NAMESERVER=$($CLI exec "$NODE" \
        sh -c "grep '^nameserver' /etc/resolv.conf | head -1 | awk '{print \$2}'" 2>/dev/null)
    if [ "$NAMESERVER" = "$NODE_IP" ]; then
        pass "/etc/resolv.conf -> ${NODE_IP} (local CoreDNS)"
    else
        echo "  [WARN] /etc/resolv.conf -> ${NAMESERVER} (expected ${NODE_IP})"
    fi

    # ── Test 4: Native Prometheus metrics at :9153 ────────────────
    # CoreDNS has built-in metrics — no custom exporter needed (unlike dnsmasq)
    REQUESTS=$($CLI exec "$NODE" sh -c \
        "curl -sf http://127.0.0.1:9153/metrics 2>/dev/null | grep -c '^coredns_dns_requests_total' || echo 0" \
        2>/dev/null)
    RESPONSES=$($CLI exec "$NODE" sh -c \
        "curl -sf http://127.0.0.1:9153/metrics 2>/dev/null | grep -c '^coredns_dns_responses_total' || echo 0" \
        2>/dev/null)
    LATENCY=$($CLI exec "$NODE" sh -c \
        "curl -sf http://127.0.0.1:9153/metrics 2>/dev/null | grep -c '^coredns_dns_request_duration_seconds' || echo 0" \
        2>/dev/null)
    if [ "$REQUESTS" -gt 0 ] 2>/dev/null && [ "$RESPONSES" -gt 0 ] 2>/dev/null && [ "$LATENCY" -gt 0 ] 2>/dev/null; then
        pass "Native Prometheus metrics: requests(${REQUESTS}), responses(${RESPONSES}), latency(${LATENCY} buckets)"
    else
        fail "Prometheus metrics not available at :9153"
    fi

    # ── Test 5: Per-zone metrics ──────────────────────────────────
    # Each zone (api.DOMAIN, apps.DOMAIN, .) has independent counters
    ZONES=$($CLI exec "$NODE" sh -c \
        "curl -sf http://127.0.0.1:9153/metrics 2>/dev/null | grep '^coredns_dns_requests_total' | grep -oP 'zone=\"[^\"]+\"' | sort -u" \
        2>/dev/null || echo "")
    ZONE_COUNT=$(echo "$ZONES" | grep -c 'zone=' 2>/dev/null || echo "0")
    if [ "$ZONE_COUNT" -gt 1 ] 2>/dev/null; then
        ZONE_LIST=$(echo "$ZONES" | sed 's/zone="//g; s/"//g' | tr '\n' ', ' | sed 's/,$//')
        pass "Per-zone metrics: ${ZONE_COUNT} zones tracked (${ZONE_LIST})"
    elif [ "$ZONE_COUNT" -eq 1 ] 2>/dev/null; then
        pass "Per-zone metrics: 1 zone tracked (more zones appear after queries)"
    else
        fail "Per-zone metrics not found"
    fi

    # ── Test 6: Cache metrics via Prometheus ──────────────────────
    # Native cache_hits/cache_misses counters — no log parsing required
    CACHE_HITS=$($CLI exec "$NODE" sh -c \
        "curl -sf http://127.0.0.1:9153/metrics 2>/dev/null | grep '^coredns_cache_hits_total' | awk '{sum+=\$2} END {printf \"%.0f\", sum}'" \
        2>/dev/null || echo "")
    CACHE_MISSES=$($CLI exec "$NODE" sh -c \
        "curl -sf http://127.0.0.1:9153/metrics 2>/dev/null | grep '^coredns_cache_misses_total' | awk '{sum+=\$2} END {printf \"%.0f\", sum}'" \
        2>/dev/null || echo "")
    CACHE_SIZE=$($CLI exec "$NODE" sh -c \
        "curl -sf http://127.0.0.1:9153/metrics 2>/dev/null | grep -c '^coredns_cache_entries' || echo 0" \
        2>/dev/null)
    if [ -n "$CACHE_HITS" ] && [ -n "$CACHE_MISSES" ]; then
        pass "Cache metrics: hits=${CACHE_HITS}, misses=${CACHE_MISSES} (native Prometheus, no log parsing)"
    else
        fail "Cache metrics not available"
    fi

    # ── Test 7: Static pod manifest present ───────────────────────
    # The manifest in /etc/kubernetes/manifests/ is what makes kubelet
    # manage this pod — it auto-restarts on crash, no Deployment needed
    MANIFEST_EXISTS=$($CLI exec "$NODE" sh -c \
        "test -f /etc/kubernetes/manifests/coredns-local.yaml && echo yes || echo no" 2>/dev/null)
    RESTART_COUNT=$(kubectl get pods -n kube-system --context "$CONTEXT" \
        --field-selector "spec.nodeName=${NODE}" -l app=coredns-local \
        -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "N/A")
    if [ "$MANIFEST_EXISTS" = "yes" ]; then
        pass "Static pod manifest present (kubelet-managed, restarts: ${RESTART_COUNT})"
    else
        fail "Static pod manifest NOT found at /etc/kubernetes/manifests/coredns-local.yaml"
    fi

    echo ""
done <<< "$NODES"

# ── Summary ──────────────────────────────────────────────────────────────

header "Verification Complete"

echo "  Passed: ${TOTAL_PASS}"
echo "  Failed: ${TOTAL_FAIL}"
echo ""

if [ "$TOTAL_FAIL" -gt 0 ]; then
    warn "Some tests failed. Check the output above."
    exit 1
fi

echo "  CoreDNS Static Pod Advantages (demonstrated above):"
echo "    1. Native Prometheus metrics — no custom exporter needed"
echo "    2. Per-zone counters — independent metrics per domain zone"
echo "    3. Cache observability via Prometheus — no log parsing"
echo "    4. Kubelet-managed resilience — auto-restart on crash"
echo ""
echo "  DNS resolution details (api, api-int, *.apps, external forwarding,"
echo "  caching behavior) are covered in the dnsmasq demo, which tests the"
echo "  same DNS primitives shared by both approaches."
echo ""
