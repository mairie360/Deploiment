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

{{- define "bffs.appSecretName" -}}
{{- $g := .Values.global | default dict -}}
{{- $s := $g.secrets | default dict -}}
{{- $s.appSecretName | default (printf "%s-app-secrets" .Release.Name) -}}
{{- end }}

{{/*
Variables injected into EVERY BFF.
The API and BFF URLs derive from global.apis.instances and
global.bffs.instances: one source of truth for the ports, and the release
name is right whatever the environment.
Takes a { root, name } context (name = the current instance, e.g. "user-bff").
*/}}
{{- define "bffs.commonEnv" -}}
- name: HOST
  value: "0.0.0.0"
- name: HOSTNAME
  value: "0.0.0.0"
{{- /*
MAIR-414: no DB_* nor REDIS_* (no BFF has a database or reads Redis, and the
database NetworkPolicy refuses them anyway), and JWT_SECRET only for the
BFFs listed in jwtSecretInstances: a compromised dependency of any other BFF
must not get what it takes to forge a token.
*/}}
{{- if has $.name ($.root.Values.jwtSecretInstances | default list) }}
- name: JWT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "bffs.appSecretName" $.root }}
      key: JWT_SECRET
{{- end }}
{{- /*
TRUST_PROXY (MAIR-226): Express `trust proxy` = loopback + the in-cluster
pod CIDR(s), so req.ip is the client address carried by X-Forwarded-For
through ingress-nginx and the fronts, never one chosen from outside.
Skipped when global.trustedProxyCIDRs is empty or when the instance sets
TRUST_PROXY itself in its `env` (no duplicate env entry).
*/}}
{{- $trusted := ((($.root.Values.global | default dict).trustedProxyCIDRs) | default list) }}
{{- $instance := (index ($.root.Values.instances | default dict) $.name) | default dict }}
{{- $overridden := false }}
{{- range ($instance.env | default list) }}
{{- if eq .name "TRUST_PROXY" }}{{ $overridden = true }}{{ end }}
{{- end }}
{{- if and $trusted (not $overridden) }}
- name: TRUST_PROXY
  value: {{ prepend $trusted "loopback" | join ", " | quote }}
{{- end }}
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
