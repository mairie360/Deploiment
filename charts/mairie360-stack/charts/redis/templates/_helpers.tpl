{{- define "redis.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "redis.selectorLabels" . }}
app.kubernetes.io/component: cache
app.kubernetes.io/part-of: mairie360
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Sélecteur immuable (inchangé). */}}
{{- define "redis.selectorLabels" -}}
app: {{ include "redis.name" . }}
{{- end -}}

{{- define "redis.podLabels" -}}
{{ include "redis.selectorLabels" . }}
app.kubernetes.io/name: {{ include "redis.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: cache
app.kubernetes.io/part-of: mairie360
{{- end -}}

{{/*
Redis ACL roles: one account per API, derived from global.apis.instances —
the same single source as the Services/URLs of that chart, so the ACL
accounts never drift from the real list of instances. No BFF reads Redis
(MAIR-414), so none gets an account. Returns a sorted YAML list.
*/}}
{{- define "redis.roles" -}}
{{- $g := .Values.global | default dict -}}
{{- $apis := (($g.apis | default dict).instances) | default dict -}}
{{- keys $apis | sortAlpha | toYaml -}}
{{- end -}}

{{/* Nom de la variable d'env portant le mot de passe ACL d'un rôle. */}}
{{- define "redis.roleEnvVar" -}}
{{- printf "%s_REDIS_PASSWORD" (. | upper | replace "-" "_") -}}
{{- end -}}

{{/* Clé, dans le Secret <release>-redis, du mot de passe ACL d'un rôle. */}}
{{- define "redis.rolePasswordKey" -}}
{{- printf "%s-password" . -}}
{{- end -}}
