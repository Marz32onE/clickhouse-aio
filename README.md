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
| `cluster.rotel.exporter.ttl` | `168h` | Retention; `<n><s\|m\|h\|d>`, `0s` = forever |
| `cluster.rotel.manageTtl` | `true` | Re-apply `ttl` to existing tables on upgrade |
| `operator.rbac.namespaced` | `true` | Role instead of ClusterRole |
| `operator.controller.watchNamespaces` | `[clickhouse]` | Must equal the release namespace |
| `cluster.clickhouse.tenants.users` | `[]` | Per-namespace read-only users |
| `cluster.*.podTemplate.topologyZoneKey` | `kubernetes.io/hostname` | Domain replicas spread across |
| `cluster.*.podTemplate.spreadPolicy` | `ScheduleAnyway` | Or `DoNotSchedule` / `""` |
| `cluster.*.podTemplate.nodeHostnameKey` | `""` | Non-empty = strict one pod per node |
| `cluster.*.podTemplate.topologySpreadConstraints` | `[]` | Escape hatch; replaces `spreadPolicy` |

Full knobs: `values.yaml` and `charts/cluster/values.yaml`.

### Retention (TTL)

Set `cluster.rotel.exporter.ttl` — a number plus `s`, `m`, `h` or `d`, with
`0s` meaning keep forever:

```bash
helm upgrade ch-aio . -n clickhouse --set cluster.rotel.exporter.ttl=30d
```

The DDL tool only writes TTL when it **creates** a table, so on an existing
install that value alone changes nothing. `cluster.rotel.manageTtl` (default on)
adds a post-upgrade Job that re-applies it with `ALTER TABLE ... MODIFY TTL`,
which is what makes the value adjustable after the first install.

The job reuses each table's own TTL expression — `Timestamp` for spans,
`TimestampTime` for logs, `Start` for the trace-id index — so it stays correct
if the DDL tool's schema changes, and falls back to those columns by table
suffix when a table currently has no TTL (otherwise `0s` would be a one-way
door). It then reads the result back from every replica through
`clusterAllReplicas` and exits non-zero on a mismatch, so a replica that was
restarting during the upgrade is picked up by the Job's retry rather than
silently left on the old retention.

All three otel tables carry `ttl_only_drop_parts = 1`: whole parts are dropped
once every row in them has expired, instead of rewriting parts to delete rows.
Retention is therefore granular to the partition, which is one day.

To retain traces and logs for different periods, turn `manageTtl` off and run
the `ALTER TABLE ... MODIFY TTL` statements yourself — the chart drives a single
value for every table.

### Operator RBAC scope

`operator.rbac.namespaced: true` gives the operator a Role/RoleBinding in its
own namespace instead of a ClusterRole, so it can only touch StatefulSets,
Secrets, PVCs and custom resources there. Two consequences:

- **The cluster must live in the operator's namespace.** Both `make
  install-operator` and `make install-cluster` use `NAMESPACE` for exactly this
  reason.
- **`controller.watchNamespaces` must list that namespace.** An empty list means
  cluster-wide, which a namespaced Role cannot serve — the operator reconciles
  nothing and only logs permission errors. The chart fails to render on that
  mismatch rather than letting it reach the cluster.

Two ClusterRoles remain when `metrics.secure` is on; they cover only the
`TokenReview`/`SubjectAccessReview` calls that authenticate metrics scrapes.

To manage clusters across several namespaces, set `operator.rbac.namespaced:
false` and either list them in `watchNamespaces` or leave it empty for
cluster-wide.

### Per-namespace read-only users

`cluster.clickhouse.tenants` generates ClickHouse users that can only read rows
whose telemetry carries their own Kubernetes namespace:

```yaml
cluster:
  clickhouse:
    tenants:
      users:
        - name: team_a                       # ClickHouse identifier
          namespaces: [team-a, team-a-staging]
        - name: team_b
          namespaces: [team-b]
          existingSecret: team-b-ch-password  # else one is generated
```

Each user gets a `readonly` profile, a `SELECT` grant on the configured tables,
and a row-policy filter on every one of them. The password is read from a Secret
through `@from_env`, so it never lands in the CR or in
`preprocessed_configs/users.xml`. Generated Secrets are named
`<cluster>-tenant-<name>-password`.

**The namespace has to be on the telemetry.** Rotel does not enrich spans with
Kubernetes metadata, so instrumented workloads must publish it themselves:

```yaml
env:
  - name: POD_NAMESPACE
    valueFrom: {fieldRef: {fieldPath: metadata.namespace}}
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: k8s.namespace.name=$(POD_NAMESPACE)
```

Rows missing the attribute belong to no tenant and are visible only to `default`.

A tenant's `existingSecret` must exist before the upgrade. The password reaches
ClickHouse as a container environment variable, so a missing Secret leaves the
ClickHouse pods in `CreateContainerConfigError` rather than just disabling that
one user.

Grants and filters are generated from the same `tenants.tables` list and cannot
drift apart, which matters more than it looks: a table a tenant can read but
that carries no filter returns **every** tenant's rows. That is also why
`otel_traces_trace_id_ts` is not in the default list — it holds only trace ids
and timestamps, so there is nothing to filter on.

### Replica placement

The operator derives scheduling rules from two keys rather than taking a raw
pod spec. The chart defaults to best-effort spreading **across nodes**, so it
works without zone labels and a cluster with fewer nodes than replicas still
schedules.

- `topologyZoneKey` — the operator emits a **required** TopologySpreadConstraint
  (`maxSkew: 1`, `DoNotSchedule`) plus a preferred PodAntiAffinity over this key.
  Defaults to `kubernetes.io/hostname`.
- `nodeHostnameKey` — a **required** PodAntiAffinity, at most one pod per node
  regardless of shard. Excess pods stay `Pending`. The chart leaves this empty:
  user-supplied `affinity` is *appended* to operator defaults, so a required rule
  from this key cannot be relaxed afterwards.
- `spreadPolicy` — chart-level, not an operator field. Renders the constraint
  that relaxes (or keeps) the operator's default over `topologyZoneKey`:
  `ScheduleAnyway`, `DoNotSchedule`, or `""` to emit nothing.
- `topologySpreadConstraints` — the raw operator field, merged into its defaults
  **by `topologyKey`**. A non-empty list replaces whatever `spreadPolicy` would
  render. Omit `labelSelector` on an entry that targets `topologyZoneKey`: the
  operator fills in the pod labels (including the shard id), and a constraint
  with an empty selector matches nothing.

Spread across AZs instead — one value:

```yaml
cluster:
  clickhouse:
    podTemplate:
      topologyZoneKey: topology.kubernetes.io/zone
```

Strict placement (one pod per node, `Pending` when nodes run out):

```yaml
cluster:
  clickhouse:
    podTemplate:
      nodeHostnameKey: kubernetes.io/hostname
      spreadPolicy: ""
```

Switching an existing cluster from strict to best-effort can deadlock: the
operator updates replicas one at a time and waits for each to become ready,
while the not-yet-updated replicas still carry the required PodAntiAffinity that
blocks the new pod. Apply the change before scaling up, or drop the stale rule
from the remaining StatefulSets to let the rollout finish.

### Deploying with ArgoCD

One Application can install operator + cluster in order. Enable
`cluster.argocd.enabled`: cluster resources get
`argocd.argoproj.io/sync-wave: "1"` (operator resources stay wave 0) plus
`SkipDryRunOnMissingResource=true`, so ArgoCD deploys the operator, waits for
it to be healthy, then syncs the CRs. The rotel DDL Job carries Helm
`post-install/post-upgrade` hooks, which ArgoCD runs as a PostSync hook.

```yaml
apiVersion: argoproj.io/v1beta1
kind: Application
metadata:
  name: clickhouse-aio
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Marz32onE/clickhouse-aio
    targetRevision: main
    path: .
    helm:
      values: |
        cluster:
          argocd:
            enabled: true
          clickhouse:
            defaultUser:
              existingSecret: ch-default-password   # create it out-of-band
              autoGenerate: false
  destination:
    server: https://kubernetes.default.svc
    namespace: clickhouse
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true    # operator CRDs exceed client-side apply limits
    retry:
      limit: 5
      backoff: {duration: 20s, factor: 2, maxDuration: 3m}
```

Notes:
- **Password must come from an existing Secret** (or a fixed value). ArgoCD
  renders manifests without cluster access, so the chart's lookup-based
  auto-generation would rotate the password every sync — the chart fails fast
  if you try.
- For accurate Application health (waves gate on it), register health checks
  for the CRs in `argocd-cm`:

```yaml
resource.customizations.health.clickhouse.com_ClickHouseCluster: |
  hs = {}
  if obj.status ~= nil and obj.status.conditions ~= nil then
    for _, c in ipairs(obj.status.conditions) do
      if c.type == "Healthy" and c.status == "True" then
        hs.status = "Healthy"; hs.message = "all shards ready"; return hs
      end
    end
  end
  hs.status = "Progressing"; hs.message = "waiting for replicas"
  return hs
resource.customizations.health.clickhouse.com_KeeperCluster: |
  hs = {}
  if obj.status ~= nil and obj.status.conditions ~= nil then
    for _, c in ipairs(obj.status.conditions) do
      if c.type == "Healthy" and c.status == "True" then
        hs.status = "Healthy"; hs.message = "keeper ready"; return hs
      end
    end
  end
  hs.status = "Progressing"; hs.message = "waiting for quorum"
  return hs
```

### Offline / air-gapped install

The operator chart is **vendored unpacked** at `charts/clickhouse-operator-helm/`
and referenced via `file://`, so `helm dependency update`, `lint`, and `install`
need no registry access — clone and install.

Still required in the air-gapped environment: the **container images**
(mirror to your private registry and override the repositories):

```
clickhouse/clickhouse-server:26.3      clickhouse/clickhouse-keeper:26.3
ghcr.io/clickhouse/clickhouse-operator:<operator tag>
streamfold/rotel:v0.2.2                streamfold/rotel-clickhouse-ddl:v0.2.2
quay.io/jetstack/cert-manager-*:v1.21.0
```

To refresh the vendored operator chart when a new release ships:

```bash
rm -rf charts/clickhouse-operator-helm
helm pull oci://ghcr.io/clickhouse/clickhouse-operator-helm \
  --version <new-version> --untar --untardir charts/
# bump dependencies[].version in Chart.yaml, then:
helm dependency update
```

### Operator-only install

Same namespace as the cluster — `operator.rbac.namespaced` scopes the operator's
Role to its own namespace. See "Operator RBAC scope" above.

```bash
helm upgrade --install ch-operator . -n clickhouse --create-namespace \
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
