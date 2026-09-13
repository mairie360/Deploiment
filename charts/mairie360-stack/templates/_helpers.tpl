{{/*
Nom du chart.
*/}}
{{- define "mairie360.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Nom complet : <release>-<chart>, ou <release> si le release contient déjà le nom.
*/}}
{{- define "mairie360.fullname" -}}
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

{{- define "mairie360.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mairie360.labels" -}}
helm.sh/chart: {{ include "mairie360.chart" . }}
{{ include "mairie360.selectorLabels" . }}
app.kubernetes.io/part-of: mairie360
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "mairie360.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mairie360.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Nom du Secret applicatif partagé (JWT_SECRET…).
*/}}
{{- define "mairie360.appSecretName" -}}
{{- default (printf "%s-app-secrets" .Release.Name) .Values.global.secrets.appSecretName -}}
{{- end }}
