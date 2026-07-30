{{/*
Expand the name of the chart.

Feeds app.kubernetes.io/name, which is part of the selector labels below, so
nameOverride is an install-time decision: a Deployment's spec.selector is
immutable and an upgrade that changes it is rejected outright.
*/}}
{{- define "cluster.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.

This is the base name every resource hangs off: the KeeperCluster and
ClickHouseCluster CRs (official examples give both the same name, which is what
makes the operator's <name>-keeper-headless / <name>-clickhouse-headless
services line up), the rotel Deployment/Service/Jobs, the generated password
Secret, and the pre-created per-replica PVCs.
*/}}
{{- define "cluster.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
ClickHouseCluster resource name. Renames only this CR — keeper.name is separate,
so setting one and not the other splits the pair the operator's headless service
names are derived from.
*/}}
{{- define "cluster.clickhouseName" -}}
{{- default (include "cluster.fullname" .) .Values.clickhouse.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
KeeperCluster resource name (defaults to the same base name as the
ClickHouseCluster)
*/}}
{{- define "cluster.keeperName" -}}
{{- default (include "cluster.fullname" .) .Values.keeper.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cluster.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "cluster.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "cluster.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cluster.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Default user password secret name
*/}}
{{- define "cluster.passwordSecretName" -}}
{{- if .Values.clickhouse.defaultUser.existingSecret }}
{{- .Values.clickhouse.defaultUser.existingSecret }}
{{- else }}
{{- printf "%s-default-password" (include "cluster.clickhouseName" .) }}
{{- end }}
{{- end }}

{{/*
TLS certificate secret names
*/}}
{{- define "cluster.clickhouseTlsSecretName" -}}
{{- if and .Values.tls.enabled .Values.tls.clickhouse.existingSecret }}
{{- .Values.tls.clickhouse.existingSecret }}
{{- else }}
{{- printf "%s-clickhouse-tls" (include "cluster.clickhouseName" .) }}
{{- end }}
{{- end }}

{{- define "cluster.keeperTlsSecretName" -}}
{{- if and .Values.tls.enabled .Values.tls.keeper.existingSecret }}
{{- .Values.tls.keeper.existingSecret }}
{{- else }}
{{- printf "%s-keeper-tls" (include "cluster.keeperName" .) }}
{{- end }}
{{- end }}

{{/*
Labels for every resource the operator creates for a CR — StatefulSets, Pods,
the headless Service, ConfigMaps, Secrets, PodDisruptionBudgets. Emitted as the
CR's spec.labels, which is the only hook the operator offers for this: the CRD's
podTemplate has no labels field, and a structural schema prunes unknown fields
without an error, so labels set there vanish between kubectl and etcd.

commonLabels flows in here as well, so a label set once at the chart level
reaches the operator-managed resources and not only the chart-managed ones.
Component labels win on a key collision.

Safe to change on a live cluster: the operator merges spec.labels into the
StatefulSet's pod template but not into spec.selector (which the API server
would refuse to update). The pod-template change does roll the StatefulSets.

Call with (dict "root" $ "extra" .Values.clickhouse.labels).
*/}}
{{- define "cluster.operatorResourceLabels" -}}
{{- include "cluster.stringMap" (merge (dict) (.extra | default dict) (.root.Values.commonLabels | default dict)) -}}
{{- end }}

{{/*
Render a map with every value coerced to a string. Both CRDs type spec.labels
and spec.annotations as map[string]string, so a value that YAML reads as a bool
or a number — `do-not-disrupt: true`, `revision: 3` — fails validation on apply.
Quoting here means values.yaml does not have to remember to.
*/}}
{{- define "cluster.stringMap" -}}
{{- $out := dict -}}
{{- range $k, $v := . -}}
{{- $_ := set $out $k (toString $v) -}}
{{- end -}}
{{- with $out }}{{ toYaml . }}{{ end }}
{{- end }}

{{/*
Guard for the two podTemplate fields the CRDs do not define. Both CRD schemas
list podTemplate as affinity/imagePullSecrets/initContainers/nodeHostnameKey/
nodeSelector/priorityClassName/runtimeClassName/schedulerName/securityContext/
serviceAccountName/terminationGracePeriodSeconds/tolerations/
topologySpreadConstraints/topologyZoneKey/volumes — no labels, no annotations,
and no x-kubernetes-preserve-unknown-fields. Failing here beats letting the API
server drop them silently.

Call with (dict "root" $ "component" "clickhouse").
*/}}
{{- define "cluster.rejectPodTemplateMetadata" -}}
{{- $c := index .root.Values .component -}}
{{- $pt := $c.podTemplate | default dict -}}
{{- range $field := list "labels" "annotations" -}}
{{- if index $pt $field -}}
{{- fail (printf "%s.podTemplate.%s is not a field the CRD accepts — the API server prunes it silently, so it would never reach the Pods. Use %s.%s instead: it sets spec.%s on the CR, which the operator merges into every resource it creates for the cluster." $.component $field $.component $field $field) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Client-facing ClickHouse Service name. Deliberately not <name>-clickhouse: the
operator already uses that exact string for the cluster Secret
(SpecificResourceName("")), and two different kinds sharing a name reads as a
mistake even though Kubernetes allows it.
*/}}
{{- define "cluster.clickhouseServiceName" -}}
{{- if .Values.clickhouse.service.name }}
{{- .Values.clickhouse.service.name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-clickhouse-client" (include "cluster.clickhouseName" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Rotel collector resource name
*/}}
{{- define "cluster.rotelName" -}}
{{- if .Values.rotel.name }}
{{- .Values.rotel.name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-rotel" (include "cluster.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Pod metadata for the rotel schema/retention Jobs. Emits the `metadata:` key
itself, since the labels below are always present.
*/}}
{{- define "cluster.rotelJobPodMetadata" -}}
{{- $jobs := .root.Values.rotel.jobs | default dict -}}
metadata:
  labels:
    {{- include "cluster.selectorLabels" .root | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
    {{- with $jobs.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with $jobs.podAnnotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}

{{/*
Scheduling block shared by the rotel schema/retention Jobs. Emits nothing when
none of the three is set.
*/}}
{{- define "cluster.rotelJobScheduling" -}}
{{- $jobs := .Values.rotel.jobs | default dict -}}
{{- with $jobs.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $jobs.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $jobs.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/*
ClickHouse service host the operator creates for the cluster
*/}}
{{- define "cluster.clickhouseHost" -}}
{{- printf "%s-clickhouse-headless.%s.svc.cluster.local" (include "cluster.clickhouseName" .) .Release.Namespace }}
{{- end }}

{{/*
HTTP endpoint rotel uses to reach ClickHouse (override via rotel.exporter.endpoint)
*/}}
{{- define "cluster.rotelClickhouseEndpoint" -}}
{{- if .Values.rotel.exporter.endpoint }}
{{- .Values.rotel.exporter.endpoint }}
{{- else }}
{{- printf "http://%s:8123" (include "cluster.clickhouseHost" .) }}
{{- end }}
{{- end }}

{{/*
Fully-qualified image reference. Registry, repository and tag are kept as three
explicit values so a mirror or air-gapped registry is a one-key override rather
than a rewrite of every repository string. An empty registry falls back to
whatever the node's container runtime resolves the bare repository against.
Call with an image dict, e.g. (include "cluster.image" .Values.rotel.image).
*/}}
{{- define "cluster.image" -}}
{{- $repository := include "cluster.imageRepository" . -}}
{{- with .tag -}}
{{- printf "%s:%s" $repository (. | toString) -}}
{{- else -}}
{{- $repository -}}
{{- end -}}
{{- end }}

{{/*
Registry-qualified repository, without the tag. The operator CRDs take
repository and tag as separate fields, so the registry has to be folded into the
repository for those.
*/}}
{{- define "cluster.imageRepository" -}}
{{- $registry := .registry | default "" | toString | trimSuffix "/" -}}
{{- if $registry -}}
{{- printf "%s/%s" $registry .repository -}}
{{- else -}}
{{- .repository -}}
{{- end -}}
{{- end }}

{{/*
Table prefix for one signal. rotel names its tables <prefix>_<signal>
(request_mapper.rs get_table_name), so the prefix is the only part of the table
name that can be customised — the _traces/_logs/_metrics_* suffixes are fixed.
rotel.exporter.<signal>.tablePrefix overrides rotel.exporter.tablePrefix.
Call with (dict "root" $ "signal" "traces").
*/}}
{{- define "cluster.rotelTablePrefix" -}}
{{- $e := .root.Values.rotel.exporter -}}
{{- $base := $e.tablePrefix | default "otel" -}}
{{- $p := dig .signal "tablePrefix" "" $e | toString | default $base -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" $p) -}}
{{- fail (printf "rotel.exporter.%s.tablePrefix %q: must be a ClickHouse identifier matching ^[A-Za-z_][A-Za-z0-9_]*$" .signal $p) -}}
{{- end -}}
{{- $p -}}
{{- end }}

{{/*
ClickHouse exporter groups for rotel's multi-exporter layout: one entry per
distinct table prefix, listing the enabled signals routed to it. Signals that
share a prefix share one exporter, and therefore one connection pool.

Both the deployment and the DDL job read this, so the exporter rotel writes
through and the tables the DDL job creates can never drift apart.

Returns YAML: [{name: ch_otel, prefix: otel, signals: [traces, logs]}]
*/}}
{{- define "cluster.rotelExporterGroups" -}}
{{- $telemetry := .Values.rotel.telemetry -}}
{{- $order := list -}}
{{- $groups := dict -}}
{{- range $signal := list "traces" "logs" "metrics" -}}
  {{- if index $telemetry $signal -}}
    {{- $prefix := include "cluster.rotelTablePrefix" (dict "root" $ "signal" $signal) -}}
    {{- if not (hasKey $groups $prefix) -}}
      {{- $order = append $order $prefix -}}
      {{- $_ := set $groups $prefix list -}}
    {{- end -}}
    {{- $_ := set $groups $prefix (append (index $groups $prefix) $signal) -}}
  {{- end -}}
{{- end -}}
{{- $out := list -}}
{{- range $prefix := $order -}}
{{- $out = append $out (dict "name" (printf "ch_%s" $prefix) "prefix" $prefix "signals" (index $groups $prefix)) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end }}

{{/*
Env block for one ClickHouse exporter. rotel reads a named exporter's settings
from ROTEL_EXPORTER_<NAME>_<FIELD> (init/config.rs args_from_env_prefix).
Call with (dict "root" $ "name" "ch_otel" "prefix" "otel").
*/}}
{{- define "cluster.rotelClickhouseExporterEnv" -}}
{{- $root := .root -}}
{{- $var := printf "ROTEL_EXPORTER_%s" (upper .name) -}}
{{- $async := $root.Values.rotel.exporter.asyncInsert | toString | lower -}}
{{- if not (has $async (list "true" "false" "1" "0")) -}}
{{- fail (printf "rotel.exporter.asyncInsert %q: must be true or false" $root.Values.rotel.exporter.asyncInsert) -}}
{{- end -}}
{{- /* The capitalisation is load-bearing. rotel types this field as String and
     reads a named exporter's config through figment, which coerces "true",
     "false", "1" and "0" to bool/number and then fails deserialisation with
     `invalid type: found bool true, expected a string`. "True"/"False" parse as
     neither, so they survive as strings, and rotel lowercases before matching
     (init/parse.rs parse_bool_value). */ -}}
{{- $asyncInsert := ternary "True" "False" (has $async (list "true" "1")) -}}
- name: {{ $var }}_ENDPOINT
  value: {{ include "cluster.rotelClickhouseEndpoint" $root | quote }}
- name: {{ $var }}_DATABASE
  value: {{ $root.Values.rotel.exporter.database | quote }}
- name: {{ $var }}_TABLE_PREFIX
  value: {{ .prefix | quote }}
- name: {{ $var }}_USER
  value: {{ $root.Values.rotel.exporter.user | quote }}
- name: {{ $var }}_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "cluster.rotelPasswordSecretName" $root | quote }}
      key: {{ include "cluster.rotelPasswordSecretKey" $root | quote }}
- name: {{ $var }}_COMPRESSION
  value: {{ $root.Values.rotel.exporter.compression | quote }}
- name: {{ $var }}_ASYNC_INSERT
  value: {{ $asyncInsert | quote }}
{{- if $root.Values.rotel.exporter.enableJson }}
- name: {{ $var }}_ENABLE_JSON
  value: "true"
{{- end }}
{{- end }}

{{/*
Secret holding the password rotel authenticates with (defaults to the
ClickHouse default-user secret)
*/}}
{{- define "cluster.rotelPasswordSecretName" -}}
{{- if .Values.rotel.exporter.existingSecret }}
{{- .Values.rotel.exporter.existingSecret }}
{{- else }}
{{- include "cluster.passwordSecretName" . }}
{{- end }}
{{- end }}

{{- define "cluster.rotelPasswordSecretKey" -}}
{{- if .Values.rotel.exporter.existingSecret }}
{{- .Values.rotel.exporter.existingSecretKey | default "password" }}
{{- else }}
{{- .Values.clickhouse.defaultUser.existingSecretKey | default "password" }}
{{- end }}
{{- end }}

{{/*
Whether the otel database uses the Replicated engine, as "true"/"" so callers
can use `if`. Validates the pairing it depends on.
*/}}
{{- define "cluster.rotelDatabaseReplicated" -}}
{{- $e := .Values.rotel.exporter.databaseEngine | default "Atomic" -}}
{{- if not (has $e (list "Replicated" "Atomic")) -}}
{{- fail (printf "rotel.exporter.databaseEngine %q: must be Replicated or Atomic" $e) -}}
{{- end -}}
{{- if eq $e "Replicated" -}}
{{- if not .Values.rotel.exporter.cluster -}}
{{- fail "rotel.exporter.databaseEngine=Replicated needs rotel.exporter.cluster set — every host has to join the database by name for the DDL log to reach it" -}}
{{- end -}}
{{- if ne .Values.rotel.exporter.engine "ReplicatedMergeTree" -}}
{{- fail (printf "rotel.exporter.databaseEngine=Replicated with engine=%s: replicating DDL to hosts that each keep their own copy of the data is not replication. Use engine=ReplicatedMergeTree, or databaseEngine=Atomic for a single replica." .Values.rotel.exporter.engine) -}}
{{- end -}}
true
{{- end -}}
{{- end }}

{{/*
Keeper path holding the Replicated database's DDL log.
*/}}
{{- define "cluster.rotelDatabaseReplicaPath" -}}
{{- .Values.rotel.exporter.databaseReplicaPath | default (printf "/clickhouse/databases/%s" .Values.rotel.exporter.database) -}}
{{- end }}

{{/*
rotel.exporter.ttl as a whole number of seconds.

The DDL tool only writes TTL at CREATE time, so the retention job re-applies it
with ALTER ... MODIFY TTL and needs a unit ClickHouse understands. "0" disables
retention.
*/}}
{{- define "cluster.rotelTtlSeconds" -}}
{{- $ttl := .Values.rotel.exporter.ttl | toString -}}
{{- if not (regexMatch "^[0-9]+[smhd]$" $ttl) -}}
{{- fail (printf "rotel.exporter.ttl %q: expected a number followed by s, m, h or d (e.g. 168h, 30d, 0s)" $ttl) -}}
{{- end -}}
{{- $n := regexFind "^[0-9]+" $ttl | int64 -}}
{{- $unit := regexFind "[smhd]$" $ttl -}}
{{- if eq $unit "m" -}}{{- $n = mul $n 60 -}}
{{- else if eq $unit "h" -}}{{- $n = mul $n 3600 -}}
{{- else if eq $unit "d" -}}{{- $n = mul $n 86400 -}}
{{- end -}}
{{- $n -}}
{{- end }}

{{/*
ArgoCD sync-wave annotations, per component. Always emitted: the annotations are
inert to `helm install`, so there is nothing to switch on. The operator subchart
is un-annotated and therefore wave 0, which every wave here sits behind.

  1  certs               cert-manager Certificates the CRs mount Secrets from
  2  keeper, pvc         KeeperCluster; the per-replica PVCs
  3  clickhouse          ClickHouseCluster
     clickhouse-service  its ClusterIP client Service
  4  rotel               the collector, which needs ClickHouse reachable

Keeper is a wave ahead of ClickHouse because the operator does not gate the
ClickHouse rollout on Keeper: reconcileClusterRevisions blocks only while the
KeeperCluster object is *missing*, and once it exists a Ready condition that is
still false is logged and passed over
(internal/controller/clickhouse/sync.go in ClickHouse/clickhouse-operator). The
keeper endpoint list is built from spec.replicas, not from running pods, so the
ClickHouse config renders and the StatefulSets roll while Keeper has no quorum.
Nothing corrupts — the server retries the connection — but `ON CLUSTER` DDL
fails and replicated tables stay read-only until quorum forms. The wave split is
what actually orders the two.

The PVCs land a wave ahead of ClickHouseCluster because a StatefulSet adopts
only a claim that already exists when it creates the Pod. A plain `helm install`
gets that from Helm's own kind ordering, which puts PersistentVolumeClaim ahead
of custom resources.

Waves only order what ArgoCD can call Healthy, and an unknown custom resource is
Healthy the moment it is created — so this degrades to apply-ordering until the
CR health checks are registered in argocd-cm. See "Deploying with ArgoCD" in the
README.

Usage: include "cluster.argocdAnnotations" "keeper"
*/}}
{{- define "cluster.argocdAnnotations" -}}
{{- $waves := dict "certs" 1 "keeper" 2 "pvc" 2 "clickhouse" 3 "clickhouse-service" 3 "rotel" 4 -}}
{{- if not (hasKey $waves .) }}
{{- fail (printf "cluster.argocdAnnotations: unknown component %q — expected one of %v" . (keys $waves | sortAlpha)) }}
{{- end -}}
argocd.argoproj.io/sync-wave: {{ index $waves . | quote }}
{{- /* Dry-run needs the CRD registered, and it is the operator's own sync that
       registers it. Core kinds are always there and need no opt-out. */}}
{{- if has . (list "certs" "keeper" "clickhouse") }}
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
{{- end }}
{{- end }}
