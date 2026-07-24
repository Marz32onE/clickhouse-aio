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
