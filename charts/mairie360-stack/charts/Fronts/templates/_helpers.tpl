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
app.kubernetes.io/part-of: mairie360
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Sélecteur commun (inchangé par rapport à la v0.1 : immuable sur un
Deployment existant). Le label `app: <nom>` est ajouté par instance.
*/}}
{{- define "fronts.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fronts.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: frontend
{{- end }}

{{/*
Variables injectées dans TOUS les fronts :
 - l'URL publique de chaque front (pour les liens inter-modules),
 - l'URL interne de chaque BFF (les fronts appellent les BFFs dans le cluster).
*/}}
{{- define "fronts.commonEnv" -}}
- name: HOSTNAME
  value: "0.0.0.0"
{{- with .Values.commonEnv }}
{{ toYaml . }}
{{- end }}
{{- $domain := .Values.global.domain }}
{{- range $frontName, $frontConfig := .Values.instances }}
{{- if $frontConfig.enabled }}
- name: {{ $frontName | upper | replace "-" "_" }}_URL
  value: {{ printf "https://%s.%s/" ($frontName | lower | replace "-front" "") $domain | quote }}
{{- end }}
{{- end }}
- name: ADMINISTRATION_FRONT_URL
  value: {{ printf "https://admin.%s/" $domain | quote }}
{{- $g := .Values.global | default dict }}
{{- $bffs := ((($g.bffs) | default dict).instances) | default dict }}
{{- range $bffName, $bffConfig := $bffs }}
- name: {{ $bffName | upper | replace "-" "_" }}_URL
  value: {{ printf "http://%s-%s:%d" $.Release.Name ($bffName | lower) (int ($bffConfig.port | default 4000)) | quote }}
{{- end }}
{{- end -}}


{{/*
TRUST_INGRESS_IP_HEADERS (MAIR-414): the fronts in
trustIngressIpHeadersInstances relay X-Forwarded-For / X-Real-IP to BFF_user,
whose per-IP rate limit (TRUST_PROXY, MAIR-226) would otherwise see the front
pod's address for every user. Same condition as TRUST_PROXY on the BFFs
(global.trustedProxyCIDRs), plus the NetworkPolicies: the header is only
trustworthy when the ingress controller, which overwrites it, is the only way
into the front pod. An instance `env` entry of the same name wins.
Takes { root, name, config }.
*/}}
{{- define "fronts.trustIngressIpHeaders" -}}
{{- $g := .root.Values.global | default dict -}}
{{- $overridden := false -}}
{{- range (.config.env | default list) -}}
{{- if eq .name "TRUST_INGRESS_IP_HEADERS" }}{{ $overridden = true }}{{ end -}}
{{- end -}}
{{- if and (has .name (.root.Values.trustIngressIpHeadersInstances | default list)) ($g.trustedProxyCIDRs | default list) (($g.networkPolicy | default dict).enabled) (not $overridden) -}}
- name: TRUST_INGRESS_IP_HEADERS
  value: "true"
{{- end -}}
{{- end -}}
