{{/* 1. FONCTIONS DE NOMMAGE (Indispensables pour NetworkPolicy et Deployment) */}}

{{- define "fronts.name" -}}
{{- default .Chart.Name .Values.nameOverride | lower | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "fronts.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | lower | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride | lower }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | lower | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | lower | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "fronts.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "fronts.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "fronts.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fronts.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: frontend
{{- end }}

---

{{/* 2. VARIABLES D'ENVIRONNEMENT COMMUNES */}}

{{- define "fronts.commonEnv" -}}
- name: PORT
  value: "3000"  # <--- CHANGÉ : de 80 à 3000
- name: REDIS_HOST
  value: {{ printf "%s-redis" .Release.Name | quote }}
- name: USER_BFF_URL
  value: {{ printf "http://%s-bff-user:4000" .Release.Name | quote }}
{{- end -}}