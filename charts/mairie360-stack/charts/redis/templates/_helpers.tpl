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
Rôles ACL Redis : un compte par API et par BFF, dérivé de
global.apis.instances / global.bffs.instances — la même source unique que
les Services/URLs de ces charts, pour ne jamais désynchroniser la liste des
comptes ACL de la liste réelle des instances. Renvoie une liste YAML triée.
*/}}
{{- define "redis.roles" -}}
{{- $g := .Values.global | default dict -}}
{{- $apis := (($g.apis | default dict).instances) | default dict -}}
{{- $bffs := (($g.bffs | default dict).instances) | default dict -}}
{{- merge (dict) $apis $bffs | keys | sortAlpha | toYaml -}}
{{- end -}}

{{/* Nom de la variable d'env portant le mot de passe ACL d'un rôle. */}}
{{- define "redis.roleEnvVar" -}}
{{- printf "%s_REDIS_PASSWORD" (. | upper | replace "-" "_") -}}
{{- end -}}

{{/* Clé, dans le Secret <release>-redis, du mot de passe ACL d'un rôle. */}}
{{- define "redis.rolePasswordKey" -}}
{{- printf "%s-password" . -}}
{{- end -}}
