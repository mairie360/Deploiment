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
Redis ACL roles: one account per API and per BFF, derived from
global.apis.instances and global.bffs.instances — the same single source as
the Services/URLs of those charts, so the ACL accounts never drift from the
real list of instances. Returns a sorted YAML list.
*/}}
{{- define "redis.roles" -}}
{{- $g := .Values.global | default dict -}}
{{- $apis := (($g.apis | default dict).instances) | default dict -}}
{{- $bffs := (($g.bffs | default dict).instances) | default dict -}}
{{- concat (keys $apis) (keys $bffs) | uniq | sortAlpha | toYaml -}}
{{- end -}}

{{/*
BFF accounts (MAIR-531): no BFF reads Redis yet (MAIR-499 will), so their
passwords are optional. A Secret sealed before them leaves Redis and the BFFs
starting; the account is then written `off` until the next seal-secrets.sh.
*/}}
{{- define "redis.optionalRoles" -}}
{{- $g := .Values.global | default dict -}}
{{- $bffs := (($g.bffs | default dict).instances) | default dict -}}
{{- keys $bffs | sortAlpha | toYaml -}}
{{- end -}}

{{/* Nom de la variable d'env portant le mot de passe ACL d'un rôle. */}}
{{- define "redis.roleEnvVar" -}}
{{- printf "%s_REDIS_PASSWORD" (. | upper | replace "-" "_") -}}
{{- end -}}

{{/* Clé, dans le Secret <release>-redis, du mot de passe ACL d'un rôle. */}}
{{- define "redis.rolePasswordKey" -}}
{{- printf "%s-password" . -}}
{{- end -}}
