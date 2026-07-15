{{/* 1. FONCTIONS DE NOMMAGE ET LABELS */}}
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

{{/* 2. VARIABLES D'ENVIRONNEMENT (Le bloc corrigé) */}}
{{- define "bffs.commonEnv" -}}
- name: PORT
  value: "4000"
- name: NODE_ENV
  value: "production"
- name: NODE_OPTIONS
  value: "--max-old-space-size=200"

# Connexion Redis
- name: REDIS_HOST
  value: {{ printf "%s-redis" .Release.Name | quote }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-redis" .Release.Name }}
      key: redis-password

# Liste dynamique des endpoints APIs
{{- $apis := dict }}
{{- if and .Values.global .Values.global.apis .Values.global.apis.instances }}
  {{- $apis = .Values.global.apis.instances }}
{{- end }}

{{- range $apiName, $apiConfig := $apis }}
- name: {{ $apiName | upper | replace "-" "_" }}_URL
  value: {{ printf "http://%s-%s:%d" $.Release.Name ($apiName | lower) (int $apiConfig.port) | quote }}
{{- end }}
{{- end -}}
