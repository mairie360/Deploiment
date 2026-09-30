{{- define "retention.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "retention.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "retention.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" -}}
{{- end -}}

{{- define "retention.labels" -}}
helm.sh/chart: {{ include "retention.chart" . }}
{{ include "retention.selectorLabels" . }}
app.kubernetes.io/component: retention
app.kubernetes.io/part-of: mairie360
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "retention.selectorLabels" -}}
app.kubernetes.io/name: {{ include "retention.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "retention.podLabels" -}}
{{ include "retention.selectorLabels" . }}
app.kubernetes.io/component: retention
app.kubernetes.io/part-of: mairie360
{{- end -}}

{{/* Postgres superuser Secret, same one liquibase and backup use: the
retention functions are SECURITY DEFINER with REVOKE ALL FROM PUBLIC, only
the owner can call them. */}}
{{- define "retention.dbSecretName" -}}
{{- $g := .Values.global | default dict -}}
{{- $db := $g.database | default dict -}}
{{- $db.secretName | default (printf "%s-database-secret" .Release.Name) -}}
{{- end -}}

{{/* Env shared with a plain psql client: libpq reads PGHOST/PGPORT/PGUSER/
PGPASSWORD/PGDATABASE itself, no flags needed. */}}
{{- define "retention.env" -}}
- name: PGHOST
  value: {{ printf "%s-database" .Release.Name | quote }}
- name: PGPORT
  value: {{ .Values.db.port | quote }}
- name: PGUSER
  valueFrom:
    secretKeyRef: { name: {{ include "retention.dbSecretName" . }}, key: POSTGRES_USER }
- name: PGPASSWORD
  valueFrom:
    secretKeyRef: { name: {{ include "retention.dbSecretName" . }}, key: POSTGRES_PASSWORD }
- name: PGDATABASE
  valueFrom:
    secretKeyRef: { name: {{ include "retention.dbSecretName" . }}, key: POSTGRES_DB }
{{- end -}}
