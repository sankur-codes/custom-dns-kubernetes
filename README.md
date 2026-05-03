# Custom DNS: Self-Hosted Node-Local DNS for Kubernetes

A more observable and secure alternative to cloud-managed DNS for Kubernetes clusters.

Every Kubernetes cluster on a public cloud silently depends on the cloud provider's DNS service (Azure DNS at `168.63.129.16`, AWS at `169.254.169.253`). If that service goes down, the cluster loses DNS for its own API server — nodes can't reach the control plane, kubelet can't renew leases, pods can't be scheduled. The cluster is effectively dead because of a dependency nobody configured and most teams never think about.

This project eliminates that dependency. It deploys CoreDNS as a kubelet-managed static pod on every node, resolving cluster-critical domains locally. No cloud DNS zones, no external queries for infrastructure domains, no metadata exposure.

## What It Does

- Deploys a CoreDNS static pod on every Kubernetes node (`hostNetwork: true`, port 53)
- Resolves `api.<domain>`, `api-int.<domain>`, and `*.apps.<domain>` locally on each node
- Forwards all other DNS queries (e.g. `google.com`) to upstream DNS as usual
- Exposes per-node Prometheus metrics for DNS queries, latency, cache, and errors
- Survives upstream DNS outages — cluster infrastructure domains keep resolving

## Architecture

```
┌──────────── Node ────────────┐
│                              │
│  kubelet                     │
│    └── CoreDNS static pod    │   ← resolves api.*, api-int.*, *.apps.*
│          port 53 (host)      │
│          port 9153 (metrics) │
│                              │
│  /etc/resolv.conf            │
│    nameserver <node-ip>      │   ← points to local CoreDNS first
│    nameserver <upstream>     │   ← fallback to upstream
│                              │
└──────────────────────────────┘
```

Each node is independently DNS-self-sufficient. If the control plane goes down, workers still resolve. If a worker goes down, other nodes are unaffected.

## Quick Start

### Prerequisites

- **Kind (local):** Podman or Docker, `make`
- **Azure:** `az` CLI, `jq`, SSH

### Configuration

All settings are in `config.env`:

```bash
# Shared
CLUSTER_NAME=custom-dns
DOMAIN=custom-dns.local
WORKER_COUNT=2

# Kind
CONTAINER_CLI=podman

# Azure
RESOURCE_GROUP=${CLUSTER_NAME}-rg
LOCATION=eastus
VM_SIZE=Standard_B2s
# ... (see config.env for full list)
```

Edit `config.env` before running any targets.

### Kind (Local Demo)

```bash
# Full lifecycle: create cluster + deploy CoreDNS + verify
make demo

# Prove it survives upstream DNS failure
make demo-failover

# Tear down
make clean
```

### Azure (Cloud Demo)

```bash
# Full lifecycle: create infra + install k3s + deploy CoreDNS + verify
make azure-demo

# Prove it survives Azure DNS failure (blocks 168.63.129.16)
make azure-failover

# Tear down (double confirms before destroying)
make azure-clean
```

## Make Targets

| Target | Description |
|---|---|
| `make demo` | Full Kind lifecycle (cluster + deploy + verify) |
| `make demo-failover` | Upstream DNS failure simulation (Kind) |
| `make status` | Show cluster and CoreDNS pod status |
| `make clean` | Delete Kind cluster |
| `make azure-demo` | Full Azure lifecycle (infra + k3s + deploy + verify) |
| `make azure-failover` | Azure DNS failure simulation |
| `make azure-status` | Show Azure cluster status |
| `make azure-clean` | Destroy all Azure resources |

Run `make help` for the complete list.

## How It Works

### CoreDNS Configuration

The Corefile template (`manifests/Corefile.template`) defines three resolution rules:

1. **`api.<domain>`** and **`api-int.<domain>`** resolve to the control-plane IP (API server)
2. **`*.apps.<domain>`** resolves to the ingress IP (first worker) via regex match
3. **Everything else** is forwarded to upstream DNS

CoreDNS runs as a static pod, which means:
- kubelet manages it directly (no Deployment, no DaemonSet, no API server dependency)
- It starts before the API server is reachable
- It restarts automatically if it crashes
- It survives API server outages

### Prometheus Metrics

Every node exposes CoreDNS metrics on `:9153`:

```bash
# Query counts by zone
curl -s http://<node-ip>:9153/metrics | grep coredns_dns_requests_total

# Latency histograms
curl -s http://<node-ip>:9153/metrics | grep coredns_dns_request_duration_seconds

# Cache hit rates
curl -s http://<node-ip>:9153/metrics | grep coredns_cache
```

See `monitoring/prometheus-scrape-config.yaml` for Prometheus scrape configuration.

## Project Structure

```
.
├── config.env                         # All configuration (edit this)
├── Makefile                           # Kind + Azure targets
├── demo.md                           # Step-by-step presenter guide
├── manifests/
│   ├── Corefile.template              # CoreDNS config (templated)
│   └── coredns-static-pod.yaml        # Static pod manifest
├── monitoring/
│   └── prometheus-scrape-config.yaml  # Prometheus scrape config
├── scripts/                           # Kind scripts
│   ├── common.sh                      # Shared utilities
│   ├── setup-kind.sh                  # Create Kind cluster
│   ├── deploy-coredns.sh              # Deploy CoreDNS to Kind nodes
│   ├── verify-dns.sh                  # 7-test verification suite
│   └── demo-failover.sh              # Upstream failure simulation
└── azure/                            # Azure scripts
    ├── setup-azure.sh                 # Create Azure infrastructure
    ├── install-k3s.sh                 # Install k3s on VMs
    ├── deploy-coredns-azure.sh        # Deploy CoreDNS to Azure VMs
    ├── verify-dns-azure.sh            # Verification via SSH
    ├── demo-failover-azure.sh         # Azure DNS failure simulation
    └── teardown-azure.sh             # Destroy Azure resources
```

## Use Cases

- **Regulated industries** (DORA, NIS2) requiring full control over DNS resolution
- **Air-gapped clusters** with no external DNS access
- **Edge / telco** deployments with unreliable connectivity
- **Multi-cloud** environments needing consistent DNS behavior
- **Security-conscious** teams wanting to eliminate DNS metadata exposure to cloud providers
- **High-availability** clusters that must survive cloud DNS outages

## Technology

Built entirely on CNCF graduated projects:
- [CoreDNS](https://coredns.io/) — DNS server
- [Kubernetes](https://kubernetes.io/) — container orchestration
- [Prometheus](https://prometheus.io/) — metrics and observability
- [k3s](https://k3s.io/) — lightweight Kubernetes (Azure path)
