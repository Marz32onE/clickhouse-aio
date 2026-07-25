{{/*
Expand the name of the chart.
*/}}
{{- define "cluster.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
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
Shared base name for CRs. Official examples use the same metadata.name for
KeeperCluster and ClickHouseCluster; the operator then creates
  <name>-keeper-headless / <name>-clickhouse-headless services.
*/}}
{{- define "cluster.clusterName" -}}
{{- default (include "cluster.fullname" .) .Values.clusterName | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
ClickHouse cluster resource name
*/}}
{{- define "cluster.clickhouseName" -}}
{{- default (include "cluster.clusterName" .) .Values.clickhouse.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Keeper cluster resource name (defaults to same base name as ClickHouseCluster)
*/}}
{{- define "cluster.keeperName" -}}
{{- default (include "cluster.clusterName" .) .Values.keeper.name | trunc 63 | trimSuffix "-" }}
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
Rotel collector resource name
*/}}
{{- define "cluster.rotelName" -}}
{{- printf "%s-rotel" (include "cluster.clusterName" .) | trunc 63 | trimSuffix "-" }}
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
Spread constraints for a podTemplate.

The operator turns topologyZoneKey into a required (DoNotSchedule) constraint
plus a preferred PodAntiAffinity, and merges user constraints into that default
by topologyKey. Relaxing it therefore means repeating topologyZoneKey with a
different whenUnsatisfiable, so spreadPolicy derives that entry instead of
making callers keep two values in sync. labelSelector is deliberately omitted:
the operator fills in the pod labels, including the shard id, and a constraint
with an empty selector matches nothing.

An explicit topologySpreadConstraints list takes over completely.

Usage: include "cluster.topologySpreadConstraints" (dict "podTemplate" .Values.<component>.podTemplate)
*/}}
{{- define "cluster.topologySpreadConstraints" -}}
{{- $pt := .podTemplate -}}
{{- $policy := $pt.spreadPolicy | default "" -}}
{{- if and $policy (not (has $policy (list "ScheduleAnyway" "DoNotSchedule"))) -}}
{{- fail (printf "podTemplate.spreadPolicy must be ScheduleAnyway, DoNotSchedule or empty, got %q" $policy) -}}
{{- end -}}
{{- if $pt.topologySpreadConstraints -}}
{{- toYaml $pt.topologySpreadConstraints -}}
{{- else if $policy -}}
{{- if not $pt.topologyZoneKey -}}
{{- fail "podTemplate.spreadPolicy needs podTemplate.topologyZoneKey set — it names the domain to spread across" -}}
{{- end -}}
- maxSkew: 1
  topologyKey: {{ $pt.topologyZoneKey }}
  whenUnsatisfiable: {{ $policy }}
{{- end -}}
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
Tenants: read-only users whose rows are restricted to their own Kubernetes
namespaces by a ClickHouse row policy.

Returns the normalized tenant list as YAML — callers parse it with
fromYamlArray. Each entry gains the derived secret name, secret key and the
environment variable the ClickHouse container reads the password from.

Namespace and user names are validated rather than escaped: both end up inside
a SQL string literal in the row-policy filter, and the Kubernetes namespace
grammar has no quote characters to escape.
*/}}
{{- define "cluster.tenantList" -}}
{{- $root := . -}}
{{- $tenants := $root.Values.clickhouse.tenants | default dict -}}
{{- $out := list -}}
{{- range $i, $u := ($tenants.users | default list) -}}
  {{- if not $u.name -}}
  {{- fail (printf "clickhouse.tenants.users[%d]: name is required" $i) -}}
  {{- end -}}
  {{- if not (regexMatch "^[a-zA-Z_][a-zA-Z0-9_]*$" $u.name) -}}
  {{- fail (printf "clickhouse.tenants.users[%d].name %q: must be a ClickHouse identifier matching ^[a-zA-Z_][a-zA-Z0-9_]*$" $i $u.name) -}}
  {{- end -}}
  {{- if not $u.namespaces -}}
  {{- fail (printf "clickhouse.tenants.users[%d] (%s): namespaces is required — a tenant with no namespaces would match no rows" $i $u.name) -}}
  {{- end -}}
  {{- range $ns := $u.namespaces -}}
    {{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $ns) -}}
    {{- fail (printf "clickhouse.tenants.users[%d] (%s): %q is not a valid Kubernetes namespace name" $i $u.name $ns) -}}
    {{- end -}}
  {{- end -}}
  {{- $secretName := $u.existingSecret | default (printf "%s-tenant-%s-password" (include "cluster.clickhouseName" $root) ($u.name | replace "_" "-")) -}}
  {{- $out = append $out (dict
        "name" $u.name
        "namespaces" $u.namespaces
        "profile" ($u.profile | default "tenant_readonly")
        "password" ($u.password | default "")
        "existingSecret" ($u.existingSecret | default "")
        "secretName" $secretName
        "secretKey" ($u.existingSecretKey | default "password")
        "envVar" (printf "CH_TENANT_%s_PASSWORD" (upper $u.name))
      ) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end }}

{{/*
Fully-qualified tables tenants may read, e.g. "otel.otel_traces".
*/}}
{{- define "cluster.tenantTables" -}}
{{- $tenants := .Values.clickhouse.tenants | default dict -}}
{{- $db := $tenants.database | default .Values.rotel.exporter.database -}}
{{- if not $db -}}
{{- fail "clickhouse.tenants.database is empty and rotel.exporter.database is unset — tenants need a database to grant on" -}}
{{- end -}}
{{- $out := list -}}
{{- range $t := ($tenants.tables | default list) -}}
{{- $out = append $out (printf "%s.%s" $db $t) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end }}

{{/*
extraUsersConfig with the generated tenant users merged in. Values supplied
under clickhouse.settings.extraUsersConfig win, so a hand-written user of the
same name replaces the generated one.

Every granted table also carries the row-policy filter: an unfiltered table the
tenant can read returns *every* row, so grants and filters are generated from
one list and never drift apart.

The `grants` mapping is a single key holding a list of query strings. A list of
{query: ...} maps renders as repeated <grants> elements and ClickHouse only
honours the first, silently dropping every grant after it.
*/}}
{{- define "cluster.extraUsersConfig" -}}
{{- $tenantList := include "cluster.tenantList" . | fromYamlArray -}}
{{- $config := deepCopy (.Values.clickhouse.settings.extraUsersConfig | default dict) -}}
{{- if $tenantList -}}
  {{- $tables := include "cluster.tenantTables" . | fromYamlArray -}}
  {{- if not $tables -}}
  {{- fail "clickhouse.tenants.tables is empty — tenants would have no readable tables" -}}
  {{- end -}}
  {{- $attr := (.Values.clickhouse.tenants.namespaceAttribute | default "k8s.namespace.name") -}}
  {{- if not (regexMatch "^[A-Za-z0-9_.-]+$" $attr) -}}
  {{- fail (printf "clickhouse.tenants.namespaceAttribute %q: must match ^[A-Za-z0-9_.-]+$" $attr) -}}
  {{- end -}}
  {{- $generated := dict -}}
  {{- $profiles := dict "tenant_readonly" (dict "readonly" 1) -}}
  {{- range $t := $tenantList -}}
    {{- $quoted := list -}}
    {{- range $ns := $t.namespaces -}}{{- $quoted = append $quoted (printf "'%s'" $ns) -}}{{- end -}}
    {{- $filter := printf "ResourceAttributes['%s'] IN (%s)" $attr (join ", " $quoted) -}}
    {{- $databases := dict -}}
    {{- $queries := list -}}
    {{- range $qualified := $tables -}}
      {{- $parts := splitList "." $qualified -}}
      {{- $db := index $parts 0 -}}
      {{- $tbl := index $parts 1 -}}
      {{- $existing := index $databases $db | default dict -}}
      {{- $_ := set $existing $tbl (dict "filter" $filter) -}}
      {{- $_ := set $databases $db $existing -}}
      {{- $queries = append $queries (printf "GRANT SELECT ON %s" $qualified) -}}
    {{- end -}}
    {{- $_ := set $generated $t.name (dict
          "password" (dict "@from_env" $t.envVar "@hide_in_preprocessed" true)
          "profile" $t.profile
          "networks" (dict "ip" "::/0")
          "databases" $databases
          "grants" (dict "query" $queries)
        ) -}}
  {{- end -}}
  {{- $merged := mergeOverwrite (dict "profiles" $profiles "users" $generated) $config -}}
  {{- $config = $merged -}}
{{- end -}}
{{- if $config -}}
{{- toYaml $config -}}
{{- end -}}
{{- end }}

{{/*
containerTemplate env with one secretKeyRef per tenant appended. User-supplied
entries come first so an explicit override of the same variable wins.
*/}}
{{- define "cluster.clickhouseEnv" -}}
{{- $env := .Values.clickhouse.containerTemplate.env | default list -}}
{{- range $t := (include "cluster.tenantList" . | fromYamlArray) -}}
  {{- $names := list -}}
  {{- range $e := $env -}}{{- $names = append $names $e.name -}}{{- end -}}
  {{- if not (has $t.envVar $names) -}}
    {{- $env = append $env (dict "name" $t.envVar "valueFrom" (dict "secretKeyRef" (dict "name" $t.secretName "key" $t.secretKey))) -}}
  {{- end -}}
{{- end -}}
{{- if $env -}}
{{- toYaml $env -}}
{{- end -}}
{{- end }}

{{/*
ArgoCD ordering annotations: cluster resources sync in a later wave than the
operator (un-annotated = wave 0), and dry-run is skipped while the CRDs the
operator ships are not registered yet.
*/}}
{{- define "cluster.argocdAnnotations" -}}
{{- if .Values.argocd.enabled }}
argocd.argoproj.io/sync-wave: {{ .Values.argocd.syncWave | quote }}
argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
{{- end }}
{{- end }}
