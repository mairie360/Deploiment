{{/*
Expand the name of the chart.
*/}}
{{- define "liquibase.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "liquibase.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "liquibase.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "liquibase.labels" -}}
helm.sh/chart: {{ include "liquibase.chart" . }}
{{ include "liquibase.selectorLabels" . }}
app.kubernetes.io/component: migration
app.kubernetes.io/part-of: mairie360
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "liquibase.selectorLabels" -}}
app.kubernetes.io/name: {{ include "liquibase.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{- define "liquibase.dbSecretName" -}}
{{- $g := .Values.global | default dict -}}
{{- $db := $g.database | default dict -}}
{{- .Values.secretName | default ($db.secretName | default (printf "%s-database-secret" .Release.Name)) -}}
{{- end }}

{{/* Postgres role name for an API instance key, e.g. "core-api" -> "core_api". */}}
{{- define "liquibase.roleName" -}}
{{- . | replace "-" "_" -}}
{{- end }}

{{/* Secret key holding a role's password, e.g. "core-api" -> "CORE_API_PASSWORD". */}}
{{- define "liquibase.rolePasswordKey" -}}
{{- printf "%s_PASSWORD" (include "liquibase.roleName" . | upper) -}}
{{- end }}
