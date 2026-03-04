{{/* 1. FONCTIONS DE NOMMAGE (Résout l'erreur "no template bffs.fullname") */}}

{{- define "bffs.name" -}}
{{- default .Chart.Name .Values.nameOverride | lower | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "bffs.fullname" -}}
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

{{- define "bffs.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "bffs.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "bffs.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bffs.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: bff
{{- end }}

---

{{/* 2. VARIABLES D'ENVIRONNEMENT (Ton bloc existant) */}}

{{- define "bffs.commonEnv" -}}
- name: PORT
  value: "4000"
- name: NODE_ENV
  value: "production"

{{/* Connexion Redis (pour les sessions/cache) */}}
- name: REDIS_HOST
  value: {{ printf "%s-redis" .Release.Name | quote }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-redis" .Release.Name }}
      key: redis-password
{{- end -}}

# Liste des endpoints APIs pour le BFF
- name: CORE_API_URL
  value: {{ printf "http://%s-core-api:3000" .Release.Name | quote }}
- name: PROJECT_API_URL
  value: {{ printf "http://%s-project-api:3001" .Release.Name | quote }}
- name: CALENDAR_API_URL
  value: {{ printf "http://%s-calendar-api:3002" .Release.Name | quote }}
- name: MESSAGE_API_URL
  value: {{ printf "http://%s-message-api:3003" .Release.Name | quote }}
- name: EMAIL_API_URL
  value: {{ printf "http://%s-email-api:3004" .Release.Name | quote }}
- name: FILES_API_URL
  value: {{ printf "http://%s-files-api:3005" .Release.Name | quote }}
- name: ELEARNING_API_URL
  value: {{ printf "http://%s-elearning-api:3006" .Release.Name | quote }}
{{- end -}}