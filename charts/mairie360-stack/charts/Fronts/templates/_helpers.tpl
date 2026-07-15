{{/* 1. FONCTIONS DE NOMMAGE */}}

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
- name: HOSTNAME
  value: "0.0.0.0"
- name: REDIS_HOST
  value: {{ printf "%s-redis" .Release.Name | quote }}

{{/* 1. URLs des Fronts avec port */}}
{{- range $frontName, $frontConfig := .Values.instances }}
{{- if $frontConfig.enabled }}
- name: {{ $frontName | upper | replace "-" "_" }}_URL
  value: {{ printf "http://%s-%s:%d" $.Release.Name ($frontName | lower) (int $frontConfig.port) | quote }}
{{- end }}
{{- end }}

{{/* 2. URLs des BFFs avec port (Approche sécurisée sans dig) */}}
{{- $bffs := dict }}
{{- if .Values.global }}
  {{- if .Values.global.bffs }}
    {{- if .Values.global.bffs.instances }}
      {{- $bffs = .Values.global.bffs.instances }}
    {{- end }}
  {{- end }}
{{- end }}

{{- range $bffName, $bffConfig := $bffs }}
- name: {{ $bffName | upper | replace "-" "_" }}_URL
  value: {{ printf "http://%s-%s:%d" $.Release.Name ($bffName | lower) (int $bffConfig.port) | quote }}
{{- end }}
{{- end -}}
