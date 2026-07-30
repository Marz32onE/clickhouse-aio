# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single Helm umbrella chart (`clickhouse`) that deploys the **Altinity ClickHouse operator** (`ClickHouseInstallation` / `ClickHouseKeeperInstallation`, `clickhouse.altinity.com/v1` + `clickhouse-keeper.altinity.com/v1`) plus a cluster built from it. There is no application code and no test suite — every change is Go-template YAML, and the only verification loop is `helm lint` / `helm template` (and a local kind install).

Upstream quick start: https://github.com/Altinity/clickhouse-operator/blob/master/docs/quick_start.md

## Commands

```bash
make deps                 # helm dependency update + remove the .tgz it leaves behind
make lint                 # deps + helm lint .
make template             # deps + helm template with a dummy password (the render check)
make package              # deps + lint + helm package -> dist/

make install-operator VALUES=values.yaml
make install-cluster  VALUES=values.yaml PASSWORD='...'   # two-step: avoids the CRD race
make install PASSWORD='...'                                # one-shot
make uninstall

# Vars: CHART_NAME, RELEASE (ch-aio), NAMESPACE (clickhouse), VALUES (values.yaml)
```

To render one subchart in isolation, `helm template ... --set cluster.enabled=false` or `--set operator.enabled=false`.

**`helm dependency update` is destructive here.** It repackages both vendored subcharts into `charts/*.tgz` beside the source directories. Helm then sees two charts of the same name and the winner is not stable, so a stale archive silently installs older templates. Always delete the archives afterwards — `make deps` does this, a bare `helm dependency update` does not.

Refreshing the vendored operator chart: `rm -rf charts/altinity-clickhouse-operator`, `helm pull altinity/altinity-clickhouse-operator --version <new> --untar --untardir charts/`, bump `dependencies[].version` in `Chart.yaml`, then `make deps`.

## Layout

```
Chart.yaml              umbrella; both deps are file:// (offline installs work from a clone)
values.yaml             the production profile — cluster.* keys override the subchart
templates/              only NOTES.txt + validate-rbac-scope.yaml
charts/altinity-clickhouse-operator/   VENDORED UPSTREAM — do not hand-edit, re-pull instead
charts/cluster/         the local subchart: CHI/CHK CRs, Rotel, and the schema/TTL Jobs
```

`charts/cluster/` is where nearly all work happens. Templates emit Altinity `ClickHouseInstallation` / `ClickHouseKeeperInstallation`. `charts/cluster/templates/_helpers.tpl` holds the naming chain, image triples, settings flattening, user conversion, Rotel exporter/env generation, and most validation.

## Two values files, one profile

`values.yaml` (root, `cluster.*`) and `charts/cluster/values.yaml` are near-mirrors: the root file is the small-business production profile and wins; the subchart file is the standalone default. They are **not** generated from each other — a key added to one and not the other drifts silently, and a comment corrected in one leaves the other wrong. Change both, and prefix correctly (`cluster.clickhouse.replicas` at the root, `clickhouse.replicas` in the subchart).

Not everything is mirrored: the root file's `settings.users` block ships an active `reporter` user where the subchart's is commented out.

## Architecture

The operator owns the Pods. The chart writes two CRs (`ClickHouseKeeperInstallation`, `ClickHouseInstallation`) and the operator creates the StatefulSets, Services, ConfigMaps and PDBs from them. Anything the chart wants on an operator-created Pod goes through CHI/CHK templates (podTemplates, volumeClaimTemplates, serviceTemplates).

The chart directly owns: the default-user Secret, TLS Certificates (optional), and the Rotel collector (Deployment / Service / HPA / DDL Job / TTL Job). The client ClusterIP Service is created by the operator from a CHI serviceTemplate.

**Rotel signal wiring is generated from one list.** `rotel.telemetry.{traces,logs,metrics}` drives the DDL Job's tables, the Deployment's exporters, and which OTLP receivers stay open. Keep them derived from that single list — they cannot be allowed to drift apart.

## Invariants the templates enforce

Templates `fail` early rather than letting a bad render reach the cluster. Every `fail` message states what is wrong, why it matters, and the fix — match that style when adding one; a bare "invalid value" is a regression here.

Current guards, all worth knowing before changing defaults:

- `operator.rbac.namespaceScoped=true` with a foreign entry in `operator.watchNamespaces` fails. Empty `watchNamespaces` means the operator's own namespace (when not in kube-system). (`templates/validate-rbac-scope.yaml`)
- `cluster.argocdAnnotations` fails on an unknown component name. Wave order: certs 1, keeper 2, clickhouse 3, rotel 4.
- `rotel.exporter.databaseEngine=Replicated` requires `exporter.cluster` set and `engine=ReplicatedMergeTree`.
- `rotel.exporter.ttl` matches `<n><s|m|h|d>`; table prefixes must be ClickHouse identifiers.
- Nested `settings.extraConfig` is flattened to Altinity slash paths; large ints avoid scientific notation.

Not enforced, but load-bearing:

- `clickhouse.shards` must stay `1`. Raising it returns one shard's rows with no error — the otel tables are plain `ReplicatedMergeTree` with no `Distributed` layer, and `rotel-clickhouse-ddl` cannot create one. See "Sharding is not a values-only change" in the README.
- `keeper.replicas` cannot change after the first successful deploy.
- `nameOverride` is install-time only (it sets `app.kubernetes.io/name`, a selector label, and Deployment selectors are immutable). `fullnameOverride` leaves labels alone.

## Users

`clickhouse.settings.extraUsersConfig` is converted to Altinity flat `configuration.users` / `profiles` keys. Passwords support plaintext, `password_sha256_hex`, `passwordSecret`, or `@from_env` resolved via `containerTemplate.env` secretKeyRef. A missing Secret for a referenced user fails CHI reconcile rather than starting without that user.

The `default` user is separate: `clickhouse.defaultUser`, with a chart-generated Secret named `<clickhouseName>-default-password` (annotated `helm.sh/resource-policy: keep`, reused across upgrades via `lookup`), referenced as `valueFrom.secretKeyRef` on the CHI.

## Images

Every image is a `registry` / `repository` / `tag` triple built through the `cluster.image` helper, so a mirror is a one-key override and no tag floats. Keep new images in that shape; do not introduce a combined `image: repo:tag` string.

## Conventions

- Comments in `values.yaml` carry the reasoning, not just the type. Several are the only record of a ClickHouse/operator behaviour that took a debugging session to find (why the otel database is `Replicated`, why the version-probe memory is bumped, why port 9363 is reserved). Preserve them; if a default changes, update its comment in both values files.
- README.md is the long-form version of the same reasoning and is expected to stay in step with behaviour changes.
- Commit subjects: conventional-commit prefixes (`feat:`, `fix:`, `refactor:`), imperative, lowercase.
