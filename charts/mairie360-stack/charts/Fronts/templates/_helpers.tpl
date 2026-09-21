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
- name: REDIS_HOST
  value: {{ printf "%s-redis" .Release.Name | quote }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-redis" .Release.Name }}
      key: redis-password
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
