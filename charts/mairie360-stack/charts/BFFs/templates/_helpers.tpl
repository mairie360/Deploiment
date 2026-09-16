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
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: bff
app.kubernetes.io/part-of: mairie360
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Sélecteur immuable d'une instance (inchangé par rapport à la v0.1). */}}
{{- define "bffs.instanceSelectorLabels" -}}
app: {{ .name }}
{{- end }}

{{- define "bffs.instancePodLabels" -}}
{{ include "bffs.instanceSelectorLabels" . }}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: bff
app.kubernetes.io/part-of: mairie360
component: bff
{{- end }}

{{- define "bffs.dbSecretName" -}}
{{- $g := .Values.global | default dict -}}
{{- $db := $g.database | default dict -}}
{{- $db.secretName | default (printf "%s-database-secret" .Release.Name) -}}
{{- end }}

{{- define "bffs.appSecretName" -}}
{{- $g := .Values.global | default dict -}}
{{- $s := $g.secrets | default dict -}}
{{- $s.appSecretName | default (printf "%s-app-secrets" .Release.Name) -}}
{{- end }}

{{/*
Variables injectées dans TOUS les BFFs.
Les URLs des APIs et des autres BFFs sont dérivées de global.apis.instances
et global.bffs.instances : une seule source de vérité pour les ports, et le
nom de release est toujours correct quel que soit l'environnement.
Prend un contexte { root, name } (name = l'instance courante, ex. "user-bff") :
c'est aussi le nom du compte ACL Redis dédié à cette instance.
*/}}
{{- define "bffs.commonEnv" -}}
- name: HOST
  value: "0.0.0.0"
- name: HOSTNAME
  value: "0.0.0.0"
- name: DB_TYPE
  value: "postgres"
- name: DB_HOST
  value: {{ printf "%s-database" $.root.Release.Name | quote }}
- name: DB_PORT
  value: "5432"
- name: DB_NAME
  valueFrom:
    secretKeyRef:
      name: {{ include "bffs.dbSecretName" $.root }}
      key: POSTGRES_DB
- name: DB_USER
  valueFrom:
    secretKeyRef:
      name: {{ include "bffs.dbSecretName" $.root }}
      key: POSTGRES_USER
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "bffs.dbSecretName" $.root }}
      key: POSTGRES_PASSWORD
- name: REDIS_HOST
  value: {{ printf "%s-redis" $.root.Release.Name | quote }}
- name: REDIS_PORT
  value: "6379"
- name: REDIS_URL
  value: {{ printf "redis://%s-redis:6379" $.root.Release.Name | quote }}
- name: REDIS_USERNAME
  value: {{ $.name | quote }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-redis" $.root.Release.Name }}
      key: {{ printf "%s-password" $.name }}
- name: JWT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "bffs.appSecretName" $.root }}
      key: JWT_SECRET
{{- with $.root.Values.commonEnv }}
{{ toYaml . }}
{{- end }}
{{- $g := $.root.Values.global | default dict }}
{{- $apis := ((($g.apis) | default dict).instances) | default dict }}
{{- range $apiName, $apiConfig := $apis }}
- name: {{ $apiName | upper | replace "-" "_" }}_URL
  value: {{ printf "http://%s-%s:%d" $.root.Release.Name ($apiName | lower) (int ($apiConfig.port | default 3000)) | quote }}
{{- end }}
{{- $bffs := ((($g.bffs) | default dict).instances) | default dict }}
{{- range $bffName, $bffConfig := $bffs }}
- name: {{ $bffName | upper | replace "-" "_" }}_URL
  value: {{ printf "http://%s-%s:%d" $.root.Release.Name ($bffName | lower) (int ($bffConfig.port | default 4000)) | quote }}
{{- end }}
{{- end -}}
