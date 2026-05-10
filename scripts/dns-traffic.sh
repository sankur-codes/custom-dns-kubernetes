#!/usr/bin/env bash
#
# dns-traffic.sh — Generate continuous DNS traffic for monitoring demos.
#
# Sends diverse DNS queries to Kind cluster nodes to populate Prometheus
# metrics, create dense Grafana dashboards, and exercise alerting rules.
#
# Usage:
#   ./dns-traffic.sh                  # Run in foreground
#   ./dns-traffic.sh --background     # Fork to background, write PID file
#
# Configuration (environment variables):
#   TRAFFIC_INTERVAL        Seconds between batches (default: 2)
#   TRAFFIC_LOCAL_COUNT     Local domain queries per batch (default: 10)
#   TRAFFIC_CACHED_COUNT    Repeated external queries per batch (default: 8)
#   TRAFFIC_FORWARD_COUNT   Unique external queries per batch (default: 5)
#   TRAFFIC_NXDOMAIN_COUNT  NXDOMAIN queries per batch (default: 3)
#   TRAFFIC_EVICT_COUNT     Cache-busting queries per batch (default: 0)
#   TRAFFIC_CLUSTER_COUNT   Cluster-internal queries per batch (default: 3)
#   TRAFFIC_STATS_EVERY     Print stats every N batches (default: 10)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/common.sh"

load_project_config

CLI="${CONTAINER_CLI:-podman}"
PIDFILE="/tmp/dns-traffic-${CLUSTER_NAME}.pid"
LOGFILE="/tmp/dns-traffic-${CLUSTER_NAME}.log"

# ── Handle --background ────────────────────────────────────────────

if [[ "${1:-}" == "--background" ]]; then
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        warn "Traffic generator already running (PID $(cat "$PIDFILE"))."
        warn "Stop it first: make traffic-stop"
        exit 1
    fi
    nohup "$0" > "$LOGFILE" 2>&1 &
    BG_PID=$!
    echo "$BG_PID" > "$PIDFILE"
    echo ""
    info "Traffic generator started (PID ${BG_PID})"
    info "Log: ${LOGFILE}"
    info "Stop: make traffic-stop"
    echo ""
    sleep 2
    tail -5 "$LOGFILE" 2>/dev/null || true
    exit 0
fi

# ── Configuration defaults ─────────────────────────────────────────

TRAFFIC_INTERVAL="${TRAFFIC_INTERVAL:-2}"
TRAFFIC_LOCAL_COUNT="${TRAFFIC_LOCAL_COUNT:-10}"
TRAFFIC_CACHED_COUNT="${TRAFFIC_CACHED_COUNT:-8}"
TRAFFIC_FORWARD_COUNT="${TRAFFIC_FORWARD_COUNT:-5}"
TRAFFIC_NXDOMAIN_COUNT="${TRAFFIC_NXDOMAIN_COUNT:-3}"
TRAFFIC_EVICT_COUNT="${TRAFFIC_EVICT_COUNT:-0}"
TRAFFIC_CLUSTER_COUNT="${TRAFFIC_CLUSTER_COUNT:-3}"
TRAFFIC_STATS_EVERY="${TRAFFIC_STATS_EVERY:-10}"

# ── PID file + signal handling ─────────────────────────────────────

echo $$ > "$PIDFILE"
RUNNING=true

cleanup() {
    rm -f "$PIDFILE"
    print_final_stats
}
trap cleanup EXIT
trap 'RUNNING=false' SIGTERM SIGINT

# ── Discover nodes ─────────────────────────────────────────────────

NODES=$($CLI ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --format '{{.Names}}' 2>/dev/null | sort)

[ -z "$NODES" ] && error "No nodes found for cluster '${CLUSTER_NAME}'. Is it running?"

declare -a NODE_NAMES=()
declare -a NODE_IPS=()

while read -r NODE; do
    IP=$($CLI inspect "$NODE" \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
    NODE_NAMES+=("$NODE")
    NODE_IPS+=("$IP")
done <<< "$NODES"

NODE_COUNT=${#NODE_NAMES[@]}

# ── Ensure dig is available on nodes ───────────────────────────────

for i in "${!NODE_NAMES[@]}"; do
    if ! $CLI exec "${NODE_NAMES[$i]}" sh -c "command -v dig" &>/dev/null; then
        info "Installing dnsutils on ${NODE_NAMES[$i]}..."
        $CLI exec "${NODE_NAMES[$i]}" sh -c \
            "apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq dnsutils >/dev/null 2>&1" \
            2>/dev/null || true
    fi
done

# ── Domain lists ───────────────────────────────────────────────────

LOCAL_DOMAINS=(
    "api.${DOMAIN}"
    "api-int.${DOMAIN}"
    "app1.apps.${DOMAIN}"
    "app2.apps.${DOMAIN}"
    "console.apps.${DOMAIN}"
    "oauth.apps.${DOMAIN}"
    "grafana.apps.${DOMAIN}"
    "prometheus.apps.${DOMAIN}"
)

QUERY_TYPES=(A AAAA MX TXT)

CACHED_DOMAINS=(
    google.com github.com reddit.com cloudflare.com amazon.com
    microsoft.com wikipedia.org stackoverflow.com kernel.org mozilla.org
)

CLUSTER_DOMAINS=(
    "kubernetes.default.svc.cluster.local"
    "kube-dns.kube-system.svc.cluster.local"
    "prometheus.monitoring.svc.cluster.local"
    "grafana.monitoring.svc.cluster.local"
)

# ── Counters ───────────────────────────────────────────────────────

TOTAL_SENT=0; TOTAL_PASS=0; TOTAL_FAIL=0
CAT_LOCAL=0; CAT_CACHED=0; CAT_FWD=0; CAT_NXDOM=0; CAT_EVICT=0; CAT_CLUSTER=0
BATCH_NUM=0
START_TIME=$(date +%s)

# ── Helpers ────────────────────────────────────────────────────────

NODE_IDX=0

next_node() {
    CURRENT_NODE="${NODE_NAMES[$NODE_IDX]}"
    CURRENT_IP="${NODE_IPS[$NODE_IDX]}"
    NODE_IDX=$(( (NODE_IDX + 1) % NODE_COUNT ))
}

send_query() {
    local node="$1" ip="$2" domain="$3" qtype="${4:-A}"
    if $CLI exec "$node" dig +short +timeout=2 +tries=1 -t "$qtype" "$domain" "@${ip}" >/dev/null 2>&1; then
        TOTAL_PASS=$((TOTAL_PASS + 1))
    else
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
    TOTAL_SENT=$((TOTAL_SENT + 1))
}

print_stats() {
    local now elapsed
    now=$(date +%s)
    elapsed=$((now - START_TIME))
    info "batch=${BATCH_NUM} | sent=${TOTAL_SENT} pass=${TOTAL_PASS} fail=${TOTAL_FAIL} | local=${CAT_LOCAL} cached=${CAT_CACHED} fwd=${CAT_FWD} nxdom=${CAT_NXDOM} evict=${CAT_EVICT} cluster=${CAT_CLUSTER} | ${elapsed}s"
}

print_final_stats() {
    echo ""
    header "Traffic Generator Stopped"
    print_stats
}

# ── Banner ─────────────────────────────────────────────────────────

header "DNS Traffic Generator"
info "Cluster:  ${CLUSTER_NAME}"
info "Domain:   ${DOMAIN}"
info "Nodes:    ${NODE_COUNT} (${NODE_NAMES[*]})"
info "Interval: ${TRAFFIC_INTERVAL}s"
BATCH_SIZE=$((TRAFFIC_LOCAL_COUNT + TRAFFIC_CACHED_COUNT + TRAFFIC_FORWARD_COUNT + TRAFFIC_NXDOMAIN_COUNT + TRAFFIC_EVICT_COUNT + TRAFFIC_CLUSTER_COUNT))
info "Batch:    ${BATCH_SIZE} queries (${TRAFFIC_LOCAL_COUNT} local + ${TRAFFIC_CACHED_COUNT} cached + ${TRAFFIC_FORWARD_COUNT} fwd + ${TRAFFIC_NXDOMAIN_COUNT} nxdom + ${TRAFFIC_EVICT_COUNT} evict + ${TRAFFIC_CLUSTER_COUNT} cluster)"
echo ""

# ── Main loop ──────────────────────────────────────────────────────

while $RUNNING; do
    BATCH_NUM=$((BATCH_NUM + 1))

    # Category 1: Local domain queries (address records / local responses)
    for ((i=0; i<TRAFFIC_LOCAL_COUNT && RUNNING; i++)); do
        next_node
        domain="${LOCAL_DOMAINS[$((i % ${#LOCAL_DOMAINS[@]}))]}"
        qtype="${QUERY_TYPES[$((i % ${#QUERY_TYPES[@]}))]}"
        send_query "$CURRENT_NODE" "$CURRENT_IP" "$domain" "$qtype"
        CAT_LOCAL=$((CAT_LOCAL + 1))
    done

    # Category 2: Repeated external domains (cache hits after first batch)
    for ((i=0; i<TRAFFIC_CACHED_COUNT && RUNNING; i++)); do
        next_node
        domain="${CACHED_DOMAINS[$((i % ${#CACHED_DOMAINS[@]}))]}"
        send_query "$CURRENT_NODE" "$CURRENT_IP" "$domain" "A"
        CAT_CACHED=$((CAT_CACHED + 1))
    done

    # Category 3: Unique external domains (forwarded, always cache miss)
    for ((i=0; i<TRAFFIC_FORWARD_COUNT && RUNNING; i++)); do
        next_node
        domain="rnd-${BATCH_NUM}-${i}-$$.fwd.test"
        send_query "$CURRENT_NODE" "$CURRENT_IP" "$domain" "A"
        CAT_FWD=$((CAT_FWD + 1))
    done

    # Category 4: Non-existent domains (NXDOMAIN responses)
    for ((i=0; i<TRAFFIC_NXDOMAIN_COUNT && RUNNING; i++)); do
        next_node
        domain="nx-${BATCH_NUM}-${i}-$$.nxdomain.test"
        send_query "$CURRENT_NODE" "$CURRENT_IP" "$domain" "A"
        CAT_NXDOM=$((CAT_NXDOM + 1))
    done

    # Category 5: Cache eviction flood (opt-in, default 0)
    for ((i=0; i<TRAFFIC_EVICT_COUNT && RUNNING; i++)); do
        next_node
        domain="evict-${BATCH_NUM}-${i}-${RANDOM}.evict.test"
        send_query "$CURRENT_NODE" "$CURRENT_IP" "$domain" "A"
        CAT_EVICT=$((CAT_EVICT + 1))
    done

    # Category 6: Cluster-internal domains (handled by kube-dns, not custom DNS)
    for ((i=0; i<TRAFFIC_CLUSTER_COUNT && RUNNING; i++)); do
        next_node
        domain="${CLUSTER_DOMAINS[$((i % ${#CLUSTER_DOMAINS[@]}))]}"
        send_query "$CURRENT_NODE" "$CURRENT_IP" "$domain" "A"
        CAT_CLUSTER=$((CAT_CLUSTER + 1))
    done

    # Periodic stats
    if (( BATCH_NUM % TRAFFIC_STATS_EVERY == 0 )); then
        print_stats
    fi

    sleep "$TRAFFIC_INTERVAL" 2>/dev/null || sleep "${TRAFFIC_INTERVAL%.*}"
done
