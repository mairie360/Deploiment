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

{{/* Labels communs (non sélecteurs). */}}
{{- define "apis.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: api
app.kubernetes.io/part-of: mairie360
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Labels de sélection d'UNE instance. Le label `app` est conservé tel quel :
spec.selector d'un Deployment est immuable, le changer obligerait à
supprimer/recréer chaque Deployment.
*/}}
{{- define "apis.instanceSelectorLabels" -}}
app: {{ .name }}
{{- end }}

{{/* Labels posés sur les pods : sélecteurs + labels standard. */}}
{{- define "apis.instancePodLabels" -}}
{{ include "apis.instanceSelectorLabels" . }}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: api
app.kubernetes.io/part-of: mairie360
component: api
{{- end }}

{{/* Port de Service d'une API, lu dans global.apis.instances (source unique). */}}
{{- define "apis.servicePort" -}}
{{- $g := dict -}}
{{- if and .root.Values.global .root.Values.global.apis .root.Values.global.apis.instances -}}
{{- $g = index .root.Values.global.apis.instances .name | default dict -}}
{{- end -}}
{{- $g.port | default 3000 -}}
{{- end }}

{{- define "apis.dbSecretName" -}}
{{- $g := .Values.global | default dict -}}
{{- $db := $g.database | default dict -}}
{{- $db.secretName | default (printf "%s-database-secret" .Release.Name) -}}
{{- end }}

{{- define "apis.appSecretName" -}}
{{- $g := .Values.global | default dict -}}
{{- $s := $g.secrets | default dict -}}
{{- $s.appSecretName | default (printf "%s-app-secrets" .Release.Name) -}}
{{- end }}

{{/*
Variables d'environnement injectées dans TOUTES les APIs.
Tous les secrets viennent de Secrets Kubernetes, jamais des values.
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
- name: DB_NAME
  valueFrom:
    secretKeyRef:
      name: {{ include "apis.dbSecretName" . }}
      key: POSTGRES_DB
- name: DB_USER
  valueFrom:
    secretKeyRef:
      name: {{ include "apis.dbSecretName" . }}
      key: POSTGRES_USER
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "apis.dbSecretName" . }}
      key: POSTGRES_PASSWORD
- name: REDIS_HOST
  value: {{ printf "%s-redis" .Release.Name | quote }}
- name: REDIS_PORT
  value: "6379"
- name: REDIS_URL
  value: {{ printf "redis://%s-redis:6379" .Release.Name | quote }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-redis" .Release.Name }}
      key: redis-password
- name: JWT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "apis.appSecretName" . }}
      key: JWT_SECRET
{{- with .Values.commonEnv }}
{{ toYaml . }}
{{- end }}
{{- end -}}
