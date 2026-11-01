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
MAIR-414: no DB_* (no BFF has a database, and the database NetworkPolicy
refuses them anyway). JWT_SECRET goes to the BFFs
listed in jwtSecretInstances: every one of them since MAIR-474 made each BFF
verify the session itself (bffs-lib `requireSession`) and fail at start
without it (MAIR-520).
*/}}
{{- if has $.name ($.root.Values.jwtSecretInstances | default list) }}
- name: JWT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "bffs.appSecretName" $.root }}
      key: JWT_SECRET
{{- end }}
{{- /*
MAIR-531: each BFF gets its own Redis ACL account (charts/redis, prefix
`<bff>:*`), wired ahead of the bffs-lib Redis client (MAIR-499); no BFF reads
it yet. Same shape as the APIs: REDIS_URL is expanded from the variables above
it, so the password (hex, URL-safe) never appears in the manifest. The key is
optional, so a Secret sealed before these accounts does not block the BFFs:
REDIS_PASSWORD is then unset and REDIS_URL keeps the literal `$(REDIS_PASSWORD)`
until the next scripts/seal-secrets.sh.
*/}}
- name: REDIS_HOST
  value: {{ printf "%s-redis" $.root.Release.Name | quote }}
- name: REDIS_PORT
  value: "6379"
- name: REDIS_USERNAME
  value: {{ $.name | quote }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-redis" $.root.Release.Name }}
      key: {{ printf "%s-password" $.name }}
      optional: true
- name: REDIS_URL
  value: {{ printf "redis://$(REDIS_USERNAME):$(REDIS_PASSWORD)@%s-redis:6379" $.root.Release.Name | quote }}
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
