# clickhouse-aio

Production-oriented **all-in-one Helm chart** for ClickHouse on Kubernetes.

| Subchart | Source | Role |
|----------|--------|------|
| **operator** | Official [`clickhouse-operator-helm`](https://clickhouse.com/blog/clickhouse-kubernetes-operator) (`oci://ghcr.io/clickhouse/clickhouse-operator-helm`) | Installs the ClickHouse Inc operator + CRDs |
| **cluster** | Local (`charts/cluster`) | Deploys `KeeperCluster` + `ClickHouseCluster` CRs, plus the [Rotel](https://github.com/rotel-dev/rotel) OTLP collector |

Default profile targets a **small-business production** footprint: HA without over-sharding.

## Why not the Altinity clickhouse chart as the second subchart?

The [Altinity clickhouse chart](https://github.com/Altinity/helm-charts/tree/main/charts/clickhouse) manages clusters via the **Altinity Operator** (`ClickHouseInstallation` / `ClickHouseKeeperInstallation` CRDs).

The [official ClickHouse Operator](https://clickhouse.com/blog/clickhouse-kubernetes-operator) uses different CRDs (`ClickHouseCluster` / `KeeperCluster` under `clickhouse.com/v1alpha1`).

They **cannot be mixed**. This chart follows the official operator and reuses **production sizing patterns** (replicas, keeper, storage, resources) commonly used with the Altinity chart.

## Architecture

```
                    ┌─────────────────────────────────────┐
                    │         clickhouse-aio (umbrella)   │
                    │  values.yaml  (small-biz production)│
                    └──────────────┬──────────────────────┘
                                   │
           ┌───────────────────────┼───────────────────────┐
           ▼                                               ▼
 ┌─────────────────────┐                     ┌──────────────────────────┐
 │ operator (official) │                     │ cluster (local subchart) │
 │ CRDs + controller   │  reconciles ──────► │ KeeperCluster (3)        │
 │ webhooks + metrics  │                     │ ClickHouseCluster (1×2)  │
 └─────────────────────┘                     └──────────────────────────┘
```

**Default topology**

| Component | Count | CPU (req–lim) | Memory (req–lim) | Disk / pod |
|-----------|-------|---------------|------------------|------------|
| ClickHouse Keeper | 3 | 500m–1 | 1–2 Gi | 20 Gi |
| ClickHouse server | 2 (1 shard) | 2–4 | 8–16 Gi | 200 Gi |
| Operator manager | 1 | 50m–500m | 128–256 Mi | — |

Total rough floor: **~4.5 CPU / ~18 Gi RAM / ~440 Gi storage** (plus headroom for merges/queries).

## Prerequisites

1. **Kubernetes** ≥ 1.28 (operator docs recommend 1.33+)
2. **Helm** ≥ 3.8 (OCI charts)
3. **cert-manager** (default operator webhooks)

```bash
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true --version v1.21.0
```

4. A **StorageClass** suitable for databases (SSD, expandable). Set:

```yaml
cluster:
  keeper:
    persistence:
      storageClassName: gp3   # EKS example
  clickhouse:
    persistence:
      storageClassName: gp3
```

## Install

```bash
# From this repo root
helm dependency update   # or: make deps
helm lint .

# Production (small business defaults)
helm upgrade --install ch-aio . \
  --namespace clickhouse \
  --create-namespace \
  --set cluster.clickhouse.defaultUser.password='CHANGE_ME_STRONG'

# Recommended first install (avoids CRD readiness race):
#   make install-operator VALUES=values.yaml
#   make install-cluster  VALUES=values.yaml PASSWORD='CHANGE_ME_STRONG'

# Or use an existing Secret
kubectl -n clickhouse create secret generic ch-default-password \
  --from-literal=password='CHANGE_ME_STRONG'
helm upgrade --install ch-aio . -n clickhouse \
  --set cluster.clickhouse.defaultUser.existingSecret=ch-default-password \
  --set cluster.clickhouse.defaultUser.autoGenerate=false
```

### Dev / local cluster

```bash
helm upgrade --install ch-aio . -n clickhouse --create-namespace -f values-dev.yaml
```

### Optional TLS

Provide a cert-manager `Issuer` / `ClusterIssuer`, then:

```bash
helm upgrade --install ch-aio . -n clickhouse \
  -f values.yaml -f values-tls.yaml \
  --set cluster.tls.issuerRef.name=local-issuer
```

## Verify

```bash
kubectl get pods,keeperclusters,clickhouseclusters -n clickhouse
kubectl get chc,keeperclusters -n clickhouse   # short names if available

# Client
kubectl exec -it -n clickhouse <clickhouse-pod> -- clickhouse-client
```

## Configuration highlights

| Key | Default | Notes |
|-----|---------|--------|
| `operator.enabled` | `true` | Set `false` if operator is already cluster-wide |
| `cluster.keeper.replicas` | `3` | **Odd only; do not change after first deploy** |
| `cluster.clickhouse.replicas` | `2` | HA pair |
| `cluster.clickhouse.shards` | `1` | Scale later if needed |
| `cluster.clickhouse.persistence.size` | `200Gi` | Per replica |
| `cluster.clickhouse.resources` | 2–4 CPU / 8–16Gi | Tune to node size |
| `cluster.tls.enabled` | `false` | Enable with `values-tls.yaml` |
| `cluster.loadBalancer.enabled` | `false` | External clients |
| `cluster.rotel.enabled` | `true` | OTLP collector (traces/logs → ClickHouse) |
| `cluster.rotel.exporter.engine` | `ReplicatedMergeTree` | `MergeTree` for single replica |
| `cluster.rotel.exporter.ttl` | `168h` | otel table row TTL |

Full knobs: `values.yaml` and `charts/cluster/values.yaml`.

### Operator-only install

```bash
helm upgrade --install ch-operator . -n clickhouse-operator-system --create-namespace \
  --set cluster.enabled=false
```

### Cluster-only (operator already installed)

```bash
helm upgrade --install ch-cluster . -n clickhouse --create-namespace \
  --set operator.enabled=false
```

## OTLP ingestion (Rotel) + ClickStack UI

The chart deploys [Rotel](https://github.com/rotel-dev/rotel), a lightweight Rust
OTLP collector, writing traces/logs into ClickHouse with the standard
OpenTelemetry ClickHouse-exporter schema (`otel.otel_traces`, `otel.otel_logs`).
A post-install Job creates the schema via `rotel-clickhouse-ddl`
(`ReplicatedMergeTree` + `ON CLUSTER default` by default — matches the operator's
cluster/macros config).

Point your apps / SDKs at:

```
OTLP/gRPC  <cluster-name>-rotel.<namespace>.svc:4317
OTLP/HTTP  <cluster-name>-rotel.<namespace>.svc:4318
```

Notes:
- Port `9363` is reserved by the operator for Prometheus metrics — the
  validation webhook rejects it in `additionalPorts`, and no `prometheus`
  entry is needed in `extraConfig`.
- The operator's version-probe Job defaults to 256Mi and OOMs with
  ClickHouse ≥ 26.x images; the chart bumps it via
  `cluster.clickhouse.versionProbe.resources`.

### Visualization

ClickHouse **26.2+** embeds the ClickStack (HyperDX) UI in the server binary at
`http://<clickhouse>:8123/clickstack` — auto-detects the `otel_*` tables, gives
search, trace waterfalls, chart explorer, and service maps with zero extra
components. No persistence for dashboards/alerts (browser-local state) — good
for dev/small teams; for full ClickStack (alerts, saved dashboards, auth) run
[HyperDX + MongoDB](https://clickhouse.com/docs/use-cases/observability/clickstack/deployment)
against this cluster, or use Grafana with the ClickHouse datasource.

## Scaling path (when the business grows)

1. Raise `cluster.clickhouse.resources` (vertical)
2. Raise `cluster.clickhouse.replicas` → `3`
3. Grow PVC size (needs expandable StorageClass)
4. Add shards (`cluster.clickhouse.shards`) for write/query scale-out
5. Enable TLS + network policies + LoadBalancer source ranges

## Uninstall

```bash
helm uninstall ch-aio -n clickhouse
# PVCs are retained by default — delete carefully
kubectl delete pvc -n clickhouse -l app.kubernetes.io/instance=ch-aio
# CRDs kept when operator.crd.keep=true
```

## References

- [Introducing the Official ClickHouse Kubernetes Operator](https://clickhouse.com/blog/clickhouse-kubernetes-operator)
- [Operator docs](https://clickhouse.com/docs/clickhouse-operator/overview)
- [Configuration guide](https://clickhouse.com/docs/clickhouse-operator/guides/configuration)
- [Altinity clickhouse chart (reference sizing)](https://github.com/Altinity/helm-charts/tree/main/charts/clickhouse)
