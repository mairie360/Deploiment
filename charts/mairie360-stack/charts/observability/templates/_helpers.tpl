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
