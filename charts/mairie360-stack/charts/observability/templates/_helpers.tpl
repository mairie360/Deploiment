{{- define "observability.fullname" -}}
{{- printf "%s-otel-collector" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "observability.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "observability.selectorLabels" . }}
app.kubernetes.io/component: telemetry
app.kubernetes.io/part-of: mairie360
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "observability.selectorLabels" -}}
app.kubernetes.io/name: otel-collector
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "observability.secretName" -}}
{{- .Values.secretName | default (printf "%s-cockpit-secret" .Release.Name) -}}
{{- end -}}

{{/* True when the collector must be rendered (single switch shared with the
APIs chart, see charts/mairie360-stack/values.yaml global.observability). */}}
{{- define "observability.enabled" -}}
{{- if ((.Values.global).observability).enabled }}true{{ end -}}
{{- end -}}

{{/* kube-state-metrics (MAIR-625). Its own component label, so the
policies that select the collector (component=telemetry) never match it. */}}
{{- define "observability.ksmName" -}}
{{- printf "%s-kube-state-metrics" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "observability.ksmSelectorLabels" -}}
app.kubernetes.io/name: kube-state-metrics
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "observability.ksmLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "observability.ksmSelectorLabels" . }}
app.kubernetes.io/component: metrics-exporter
app.kubernetes.io/part-of: mairie360
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* postgres_exporter (MAIR-626). */}}
{{- define "observability.pgExporterName" -}}
{{- printf "%s-postgres-exporter" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "observability.pgExporterSelectorLabels" -}}
app.kubernetes.io/name: postgres-exporter
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "observability.pgExporterLabels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "observability.pgExporterSelectorLabels" . }}
app.kubernetes.io/component: metrics-exporter
app.kubernetes.io/part-of: mairie360
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Same Secret as the database and the backup CronJob. */}}
{{- define "observability.databaseSecretName" -}}
{{- $g := .Values.global | default dict -}}
{{- $db := $g.database | default dict -}}
{{- $db.secretName | default (printf "%s-database-secret" .Release.Name) -}}
{{- end -}}
