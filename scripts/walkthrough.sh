#!/usr/bin/env bash
#
# walkthrough.sh — Interactive feature walkthrough for the CoreDNS static pod demo.
#
# Assumes `make demo` has already been run (cluster up, CoreDNS deployed,
# demo-apps deployed, monitoring deployed, port-forwards running).
#
# Focuses on CoreDNS-specific differentiators:
#   - Static pod architecture (kubelet-managed, two CoreDNS instances)
#   - Native Prometheus observability (per-zone metrics, latency histograms)
#   - Resilience (kill + auto-restart, manifest removal/restoration)
#
# DNS resolution basics (domain checks, forwarding, caching behavior,
# failover) are covered by the dnsmasq walkthrough and not repeated here.
#
# Usage: ./walkthrough.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/common.sh"

load_project_config

CLI="${CONTAINER_CLI:-podman}"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
CP_NODE="${CLUSTER_NAME}-control-plane"
WORKER_NODE="${CLUSTER_NAME}-worker"

# ── Preflight check ──────────────────────────────────────────────────

NODES=$($CLI ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --format '{{.Names}}' 2>/dev/null | sort)

if [ -z "$NODES" ]; then
    error "Cluster '${CLUSTER_NAME}' not running. Run 'make demo' first."
fi

CP_IP=$($CLI inspect "$CP_NODE" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
WORKER_IP=$($CLI inspect "$WORKER_NODE" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)

# Ensure dig is available
$CLI exec "$CP_NODE" sh -c "command -v dig >/dev/null 2>&1" 2>/dev/null || \
    $CLI exec "$CP_NODE" sh -c \
        "apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq dnsutils >/dev/null 2>&1" \
        2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════
#  Start
# ═══════════════════════════════════════════════════════════════════

header "CoreDNS Static Pods on Kubernetes — Interactive Walkthrough"

echo "  Cluster:     ${CLUSTER_NAME}"
echo "  Domain:      ${DOMAIN}"
echo "  Control-plane: ${CP_NODE} (${CP_IP})"
echo "  Worker:      ${WORKER_NODE} (${WORKER_IP})"
echo "  Prometheus:  http://localhost:${PROMETHEUS_PORT}"
echo "  Grafana:     http://localhost:${GRAFANA_PORT}"
echo ""
echo "  This walkthrough covers the CoreDNS static pod approach:"
echo "    1. Cluster overview & static pod architecture"
echo "    2. Two CoreDNS instances — kube-dns vs coredns-local"
echo "    3. Corefile configuration with per-zone server blocks"
echo "    4. Built-in Prometheus metrics (no exporter needed)"
echo "    5. Grafana dashboard & traffic generation"
echo "    6. Static pod resilience (self-healing & manifest lifecycle)"
echo "    7. Wrap up"

pause "Start the walkthrough?"

# ═══════════════════════════════════════════════════════════════════
#  1. Cluster Overview & Static Pod Architecture
# ═══════════════════════════════════════════════════════════════════

header "1. Cluster Overview & Static Pod Architecture"

echo "  Show the Kind cluster nodes and the custom CoreDNS static pods."
echo ""
show_cmd "kubectl get nodes -o wide --context ${KUBE_CONTEXT}"

pause

kubectl get nodes -o wide --context "$KUBE_CONTEXT"

echo ""
echo "  CoreDNS static pods (kubelet-managed, one per node):"
echo ""
show_cmd "kubectl get pods -n kube-system -l app=coredns-local -o wide --context ${KUBE_CONTEXT}"

pause

kubectl get pods -n kube-system -l app=coredns-local -o wide --context "$KUBE_CONTEXT"

echo ""
echo "  These are static pods — managed directly by kubelet, not by a Deployment."
echo "  kubelet watches a manifest file on each node's filesystem."
echo "  They survive API server outages and auto-restart if they crash."
echo ""
echo "  The static pod manifest on each node:"
show_cmd "${CLI} exec ${CP_NODE} cat /etc/kubernetes/manifests/coredns-local.yaml"

pause

$CLI exec "$CP_NODE" cat /etc/kubernetes/manifests/coredns-local.yaml

pause "Next: two CoreDNS instances"

# ═══════════════════════════════════════════════════════════════════
#  2. Two CoreDNS Instances — kube-dns vs coredns-local
# ═══════════════════════════════════════════════════════════════════

header "2. Two CoreDNS Instances in This Cluster"

echo "  This cluster runs TWO separate CoreDNS instances:"
echo ""
echo "    1. kube-dns (Deployment) — handles *.svc.cluster.local"
echo "       Standard Kubernetes DNS, managed by the control plane."
echo ""
echo "    2. coredns-local (Static Pods) — handles custom infrastructure domains"
echo "       Our custom DNS layer, managed by kubelet on each node."
echo ""

echo "  The kube-dns Deployment (standard Kubernetes DNS):"
show_cmd "kubectl get deploy coredns -n kube-system --context ${KUBE_CONTEXT}"

pause

kubectl get deploy coredns -n kube-system --context "$KUBE_CONTEXT" 2>/dev/null || true

echo ""
echo "  Our custom CoreDNS static pods (no Deployment — kubelet manages these):"
show_cmd "kubectl get pods -n kube-system -l app=coredns-local --context ${KUBE_CONTEXT}"

pause

kubectl get pods -n kube-system -l app=coredns-local --context "$KUBE_CONTEXT"

echo ""
echo "  All kube-system pods together — notice both sets:"
show_cmd "kubectl get pods -n kube-system -o wide --context ${KUBE_CONTEXT}"

pause

kubectl get pods -n kube-system -o wide --context "$KUBE_CONTEXT"

echo ""
echo "  The coredns-local pods have node names in their pod name"
echo "  (e.g., coredns-local-${CP_NODE}). They are NOT managed by any"
echo "  Deployment or DaemonSet — kubelet watches the manifest file on each node."

pause "Next: Corefile configuration"

# ═══════════════════════════════════════════════════════════════════
#  3. Corefile Configuration
# ═══════════════════════════════════════════════════════════════════

header "3. Corefile Configuration"

echo "  The Corefile defines per-zone server blocks. Each zone gets its own"
echo "  'prometheus' directive, giving us independent metrics per domain."
echo "  The 'template' plugin synthesizes DNS records on the fly."
echo ""
show_cmd "${CLI} exec ${CP_NODE} cat /etc/coredns/Corefile"

pause

$CLI exec "$CP_NODE" cat /etc/coredns/Corefile

echo ""
echo "  Four server blocks:"
echo "    - api.${DOMAIN}       -> control-plane IP (template plugin)"
echo "    - api-int.${DOMAIN}   -> control-plane IP (template plugin)"
echo "    - apps.${DOMAIN}      -> ingress IP (regex wildcard match)"
echo "    - . (catch-all)       -> forwards to upstream DNS, caches 30s"
echo ""
echo "  Each block includes 'prometheus' — per-zone metrics with zero config."
echo "  This is a key difference from dnsmasq: CoreDNS natively exposes"
echo "  Prometheus metrics at :9153 without needing a custom exporter."

pause "Next: built-in Prometheus metrics"

# ═══════════════════════════════════════════════════════════════════
#  4. Built-in Prometheus Metrics (No Exporter Needed)
# ═══════════════════════════════════════════════════════════════════

header "4. Built-in Prometheus Metrics (No Exporter Needed)"

echo "  CoreDNS has a native 'prometheus' plugin — every CoreDNS binary"
echo "  exposes metrics at :9153 out of the box. No sidecar, no exporter"
echo "  binary, no log parsing. Just add 'prometheus' to the Corefile."
echo ""
echo "  Available metrics (all built-in):"
echo "    coredns_dns_requests_total        — per zone, per type, per node"
echo "    coredns_dns_responses_total       — per rcode (NOERROR, NXDOMAIN, SERVFAIL)"
echo "    coredns_dns_request_duration_seconds — latency histogram (p50/p95/p99)"
echo "    coredns_cache_hits_total          — cache hits by type (success/denial)"
echo "    coredns_cache_misses_total        — cache misses"
echo "    coredns_proxy_request_duration_seconds — upstream forward latency histogram"
echo ""

echo "  Per-zone request counters:"
show_cmd "${CLI} exec ${CP_NODE} curl -s http://127.0.0.1:9153/metrics | grep coredns_dns_requests_total"

pause

$CLI exec "$CP_NODE" curl -s http://127.0.0.1:9153/metrics 2>/dev/null | grep "^coredns_dns_requests_total" | head -10

echo ""
echo "  Response codes (NOERROR, NXDOMAIN, SERVFAIL):"
show_cmd "${CLI} exec ${CP_NODE} curl -s http://127.0.0.1:9153/metrics | grep coredns_dns_responses_total"

pause

$CLI exec "$CP_NODE" curl -s http://127.0.0.1:9153/metrics 2>/dev/null | grep "^coredns_dns_responses_total" | head -10

echo ""
echo "  Latency histogram (enables p50/p95/p99 calculations):"
show_cmd "${CLI} exec ${CP_NODE} curl -s http://127.0.0.1:9153/metrics | grep coredns_dns_request_duration_seconds"

pause

$CLI exec "$CP_NODE" curl -s http://127.0.0.1:9153/metrics 2>/dev/null | grep "^coredns_dns_request_duration_seconds" | head -15

echo ""
echo "  Compare with dnsmasq: there, we needed a custom Go exporter that"
echo "  queries CHAOS TXT records and parses log files. Here, CoreDNS"
echo "  provides everything natively — Prometheus just scrapes :9153."

pause "Next: Grafana dashboard & traffic"

# ═══════════════════════════════════════════════════════════════════
#  5. Grafana Dashboard & Traffic Generation
# ═══════════════════════════════════════════════════════════════════

header "5. Grafana Dashboard & Traffic Generation"

echo "  The Grafana dashboard visualizes all the native CoreDNS metrics."
echo "  Port-forwards should already be running from 'make demo'."
echo ""
echo -e "  ${_BOLD}Grafana:${_RESET}     http://localhost:${GRAFANA_PORT}"
echo "               Navigate to Dashboards -> CoreDNS - Custom DNS Observability"
echo ""
echo -e "  ${_BOLD}Prometheus:${_RESET}  http://localhost:${PROMETHEUS_PORT}"
echo "               Navigate to Alerts to see configured alert rules"
echo ""
echo "  Dashboard panels:"
echo "    Overview:  Total QPS, Error Rate, Instances Up, Cache Hit Rate"
echo "    SLI/SLO:   Availability (99.9%), Latency (99% < 100ms), p99 Latency"
echo "    Queries:   QPS by Zone, Responses by Code, QPS by Node, QPS by Type"
echo "    Latency:   Request Latency (p50/p95/p99), Forward Latency, Latency by Zone"
echo "    Cache:     Cache Hits vs Misses, Forward Requests by Upstream"
echo ""
echo "  Prometheus alerts:"
echo "    - CoreDNSDown (critical) — instance unreachable for 1m"
echo "    - CoreDNSHighSERVFAILRate (warning) — SERVFAIL > 1% for 5m"
echo "    - CoreDNSLatencyP99High (warning) — p99 > 100ms for 5m"
echo "    - CoreDNSCacheHitRateLow (info) — cache hit rate < 50% for 10m"
echo "    - CoreDNSAvailabilitySLOBreach (critical) — availability < 99.9% for 5m"
echo ""
echo "  Let's start DNS traffic to see the dashboard come alive."
echo ""
echo "  Traffic mix per batch (every 2s):"
echo "    10 local domains, 8 cached external, 5 unique external,"
echo "    3 NXDOMAIN, 3 cluster-internal (bypasses custom CoreDNS)"
echo ""
show_cmd "make -C ${REPO_DIR} traffic"

pause "Start traffic generator?"

make -C "$REPO_DIR" traffic

echo ""
echo -e "  ${_BOLD}Check the Grafana dashboard now:${_RESET} http://localhost:${GRAFANA_PORT}"
echo ""
echo "  Watch for these changes on the dashboard:"
echo "    - Total QPS ramping up"
echo "    - QPS by Zone: separate lines for api.*, apps.*, and '.' (catch-all)"
echo "    - Latency by Zone: local zones near 0ms, catch-all higher (upstream round-trip)"
echo "    - Responses by Code: NOERROR dominant, NXDOMAIN for bad domains"
echo "    - Cache Hit Rate climbing as repeated queries hit the cache"
echo "    - Forward Requests showing traffic to upstream DNS servers"

pause "Next: static pod resilience"

# ═══════════════════════════════════════════════════════════════════
#  6. Static Pod Resilience
# ═══════════════════════════════════════════════════════════════════

header "6. Static Pod Resilience"

echo "  Static pods are managed by kubelet, not a Deployment controller."
echo "  When the process crashes, kubelet auto-restarts it within seconds."
echo "  This is the architectural advantage of CoreDNS static pods."
echo ""

echo "  Step 1: Show current pod status (note RESTARTS column)"
show_cmd "kubectl get pods -n kube-system -l app=coredns-local -o wide --context ${KUBE_CONTEXT}"

pause

kubectl get pods -n kube-system -l app=coredns-local -o wide --context "$KUBE_CONTEXT"

BEFORE_RESTARTS=$(kubectl get pods -n kube-system -l app=coredns-local --context "$KUBE_CONTEXT" \
    --field-selector "spec.nodeName=${WORKER_NODE}" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
echo ""
echo -e "  Current RESTARTS for ${WORKER_NODE}: ${_GREEN}${BEFORE_RESTARTS}${_RESET}"

echo ""
echo "  Step 2: Kill CoreDNS on ${WORKER_NODE}"
show_cmd "${CLI} exec ${WORKER_NODE} kill \$(${CLI} exec ${WORKER_NODE} pgrep -f 'coredns.*Corefile')"

pause "Kill CoreDNS?"

COREDNS_PID=$($CLI exec "$WORKER_NODE" pgrep -f 'coredns.*Corefile' 2>/dev/null || echo "")
if [ -z "$COREDNS_PID" ]; then
    warn "CoreDNS not running on ${WORKER_NODE}. Skipping."
else
    echo -e "  CoreDNS PID: ${_GREEN}${COREDNS_PID}${_RESET}"
    $CLI exec "$WORKER_NODE" kill "$COREDNS_PID" 2>/dev/null || true

    echo ""
    echo "  Step 3: Verify port 53 is down"
    show_cmd "${CLI} exec ${WORKER_NODE} ss -ulnp | grep :53"

    pause

    PORT_CHECK=$($CLI exec "$WORKER_NODE" ss -ulnp 2>/dev/null | grep ":53" || true)
    if [ -z "$PORT_CHECK" ]; then
        echo -e "  ${_GREEN}Port 53 is unbound — CoreDNS is down.${_RESET}"
    else
        echo -e "  ${_YELLOW}Port 53 still bound (kubelet may have already restarted it):${_RESET}"
        echo "  ${PORT_CHECK}"
    fi

    echo ""
    echo -e "  ${_BOLD}Check Grafana now:${_RESET} http://localhost:${GRAFANA_PORT}"
    echo "  'Instances Up' should momentarily drop from 3 to 2."
    echo ""
    echo "  Step 4: Wait for kubelet to auto-restart the static pod..."
    echo "  (kubelet detects the exit and restarts within ~5 seconds)"

    sleep 6

    show_cmd "${CLI} exec ${WORKER_NODE} ss -ulnp | grep :53"

    PORT_CHECK=$($CLI exec "$WORKER_NODE" ss -ulnp 2>/dev/null | grep ":53" || true)
    if [ -n "$PORT_CHECK" ]; then
        echo -e "  ${_GREEN}Port 53 is back — kubelet restarted CoreDNS!${_RESET}"
    else
        echo -e "  ${_RED}Port 53 still down — waiting a few more seconds...${_RESET}"
        sleep 5
        PORT_CHECK=$($CLI exec "$WORKER_NODE" ss -ulnp 2>/dev/null | grep ":53" || true)
        if [ -n "$PORT_CHECK" ]; then
            echo -e "  ${_GREEN}Port 53 is back — kubelet restarted CoreDNS!${_RESET}"
        else
            echo -e "  ${_RED}CoreDNS did not restart. Check kubelet logs.${_RESET}"
        fi
    fi

    echo ""
    echo "  Step 5: Check RESTARTS column — should have incremented"
    show_cmd "kubectl get pods -n kube-system -l app=coredns-local -o wide --context ${KUBE_CONTEXT}"

    pause

    kubectl get pods -n kube-system -l app=coredns-local -o wide --context "$KUBE_CONTEXT"

    AFTER_RESTARTS=$(kubectl get pods -n kube-system -l app=coredns-local --context "$KUBE_CONTEXT" \
        --field-selector "spec.nodeName=${WORKER_NODE}" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
    echo ""
    echo -e "  RESTARTS before: ${BEFORE_RESTARTS} -> after: ${_GREEN}${AFTER_RESTARTS}${_RESET}"
    echo ""
    echo "  kubelet IS the watchdog. No systemd, no supervisor, no external process."
    echo "  The static pod self-healed within seconds."
    echo ""
    echo "  On Grafana, 'Instances Up' should already be back to 3."
    echo "  The 'CoreDNSRestarted' alert may have fired briefly."

    pause "Next: sustained failure via manifest removal"

    # ── Sustained failure (manifest removal) ──────────────────────

    header "6b. Sustained Failure — Manifest Removal"

    echo "  To permanently stop a static pod, remove its manifest file."
    echo "  kubelet stops watching for it and the pod disappears."
    echo ""
    echo "  Step 1: Remove the static pod manifest on ${WORKER_NODE}"
    show_cmd "${CLI} exec ${WORKER_NODE} mv /etc/kubernetes/manifests/coredns-local.yaml /tmp/coredns-local.yaml"

    pause "Remove the manifest?"

    $CLI exec "$WORKER_NODE" mv /etc/kubernetes/manifests/coredns-local.yaml /tmp/coredns-local.yaml 2>/dev/null || true

    echo ""
    echo "  Waiting for kubelet to stop the pod (~10-15 seconds)..."
    sleep 12

    echo ""
    echo "  Step 2: Check pods — the worker's static pod should be gone"
    show_cmd "kubectl get pods -n kube-system -l app=coredns-local -o wide --context ${KUBE_CONTEXT}"

    pause

    kubectl get pods -n kube-system -l app=coredns-local -o wide --context "$KUBE_CONTEXT"

    echo ""
    echo -e "  ${_BOLD}Check Grafana now:${_RESET} http://localhost:${GRAFANA_PORT}"
    echo "  Wait 15-30 seconds for the next Prometheus scrape."
    echo "  'Instances Up' should drop from 3 to 2."
    echo "  'CoreDNSDown' alert should transition to pending/firing."

    pause "Restore the manifest?"

    echo ""
    echo "  Step 3: Restore the manifest — kubelet picks it up and starts the pod"
    show_cmd "${CLI} exec ${WORKER_NODE} mv /tmp/coredns-local.yaml /etc/kubernetes/manifests/coredns-local.yaml"

    $CLI exec "$WORKER_NODE" mv /tmp/coredns-local.yaml /etc/kubernetes/manifests/coredns-local.yaml 2>/dev/null || true

    echo ""
    echo "  Waiting for CoreDNS to restart..."
    sleep 12

    echo ""
    echo "  Step 4: Verify pod is back"
    show_cmd "kubectl get pods -n kube-system -l app=coredns-local -o wide --context ${KUBE_CONTEXT}"

    kubectl get pods -n kube-system -l app=coredns-local -o wide --context "$KUBE_CONTEXT"

    PORT_CHECK=$($CLI exec "$WORKER_NODE" ss -ulnp 2>/dev/null | grep ":53" || true)
    if [ -n "$PORT_CHECK" ]; then
        echo ""
        echo -e "  ${_GREEN}CoreDNS is back on port 53. Grafana will return to 3 on next scrape.${_RESET}"
    else
        echo ""
        echo -e "  ${_YELLOW}CoreDNS may still be starting. Give it a few more seconds.${_RESET}"
    fi

    echo ""
    echo "  Resilience summary:"
    echo "    - Kill process  -> kubelet auto-restarts in seconds (self-healing)"
    echo "    - Remove manifest -> pod stops permanently (controlled shutdown)"
    echo "    - Restore manifest -> pod comes back (controlled start)"
fi

# ═══════════════════════════════════════════════════════════════════
#  7. Stop Traffic & Wrap Up
# ═══════════════════════════════════════════════════════════════════

pause "Next: wrap up"

header "7. Wrap Up"

echo "  Stopping the traffic generator."
show_cmd "make -C ${REPO_DIR} traffic-stop"

pause

make -C "$REPO_DIR" traffic-stop 2>/dev/null || true

header "Walkthrough Complete"

echo "  Dashboards still running:"
echo "    Grafana:     http://localhost:${GRAFANA_PORT}"
echo "    Prometheus:  http://localhost:${PROMETHEUS_PORT}"
echo ""
echo "  To tear down: make clean"
echo ""
