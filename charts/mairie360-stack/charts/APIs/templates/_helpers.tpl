{{/* 1. FONCTIONS DE NOMMAGE (Résout l'erreur "no template apis.fullname")
*/}}

{{- define "apis.name" -}}
{{- default .Chart.Name .Values.nameOverride | lower | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "apis.fullname" -}}
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

{{- define "apis.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "apis.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "apis.selectorLabels" -}}
app.kubernetes.io/name: {{ include "apis.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

---

{{/* 2. VARIABLES D'ENVIRONNEMENT COMMUNES
*/}}

{{- define "apis.commonEnv" -}}
- name: HOST
  value: "0.0.0.0"
- name: PORT
  value: "3000"
- name: DB_TYPE
  value: "postgres"
- name: DB_HOST
  value: {{ printf "%s-database" .Release.Name | quote }}
- name: DB_PORT
  value: "5432"
- name: TOKIO_WORKER_THREADS
  value: "2"

{{/* --- POSTGRES SECRETS --- */}}
- name: DB_NAME
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-database-secret" .Release.Name }}
      key: POSTGRES_DB
- name: DB_USER
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-database-secret" .Release.Name }}
      key: POSTGRES_USER
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-database-secret" .Release.Name }}
      key: POSTGRES_PASSWORD

{{/* --- REDIS CONFIG --- */}}
- name: REDIS_HOST
  value: {{ printf "%s-redis" .Release.Name | quote }}
- name: REDIS_PORT
  value: "6379"
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-redis" .Release.Name }}
      key: redis-password

- name: REDIS_URL
  value: {{ printf "redis://%s-redis:6379" .Release.Name | quote }}
{{- end -}}