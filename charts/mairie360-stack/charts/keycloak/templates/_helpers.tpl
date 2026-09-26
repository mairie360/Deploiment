{{- define "keycloak.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "keycloak.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "keycloak.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" -}}
{{- end -}}

{{/* Common (non-selector) labels of the Keycloak server objects. */}}
{{- define "keycloak.labels" -}}
helm.sh/chart: {{ include "keycloak.chart" . }}
{{ include "keycloak.selectorLabels" . }}
app.kubernetes.io/component: keycloak
app.kubernetes.io/part-of: mairie360
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "keycloak.selectorLabels" -}}
app: {{ include "keycloak.name" . }}
{{- end -}}

{{- define "keycloak.podLabels" -}}
{{ include "keycloak.selectorLabels" . }}
app.kubernetes.io/name: {{ include "keycloak.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: keycloak
app.kubernetes.io/part-of: mairie360
{{- end -}}

{{/* Keycloak's own PostgreSQL. */}}
{{- define "keycloak.db.fullname" -}}
{{- printf "%s-db" (include "keycloak.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "keycloak.db.labels" -}}
helm.sh/chart: {{ include "keycloak.chart" . }}
{{ include "keycloak.db.selectorLabels" . }}
app.kubernetes.io/component: keycloak-db
app.kubernetes.io/part-of: mairie360
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "keycloak.db.selectorLabels" -}}
app: {{ printf "%s-db" (include "keycloak.name" .) }}
{{- end -}}

{{- define "keycloak.db.podLabels" -}}
{{ include "keycloak.db.selectorLabels" . }}
app.kubernetes.io/name: {{ printf "%s-db" (include "keycloak.name" .) }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: keycloak-db
app.kubernetes.io/part-of: mairie360
{{- end -}}

{{- define "keycloak.secretName" -}}
{{- printf "%s-secret" (include "keycloak.fullname" .) -}}
{{- end -}}

{{- define "keycloak.realmConfigMapName" -}}
{{- printf "%s-realm" (include "keycloak.fullname" .) -}}
{{- end -}}

{{/* Shared app Secret (SMTP_PASSWORD), same helper as the APIs/BFFs charts. */}}
{{- define "keycloak.appSecretName" -}}
{{- $g := .Values.global | default dict -}}
{{- $s := $g.secrets | default dict -}}
{{- $s.appSecretName | default (printf "%s-app-secrets" .Release.Name) -}}
{{- end -}}

{{/*
Public hostname of Keycloak: global.keycloak.hostname, else auth.<global.domain>.
Kept identical to "mairie360.keycloakHost" in the umbrella chart, which
renders the Ingress for it.
*/}}
{{- define "keycloak.hostname" -}}
{{- $g := .Values.global | default dict -}}
{{- $kc := $g.keycloak | default dict -}}
{{- $kc.hostname | default (printf "auth.%s" (required "global.domain is required (Keycloak public hostname)" $g.domain)) -}}
{{- end -}}

{{/* Realm name, shared with the BFFs through global.keycloak.realm. */}}
{{- define "keycloak.realmName" -}}
{{- $g := .Values.global | default dict -}}
{{- $kc := $g.keycloak | default dict -}}
{{- $kc.realm | default "mairie360" -}}
{{- end -}}

{{/* Public URL of the login front, default redirect target of both clients. */}}
{{- define "keycloak.loginUrl" -}}
{{- $g := .Values.global | default dict -}}
{{- printf "https://login.%s" (required "global.domain is required (Keycloak client redirect URIs)" $g.domain) -}}
{{- end -}}

{{/* Redirect URIs of a client: the values list, else https://login.<domain>/* */}}
{{- define "keycloak.clientRedirectUris" -}}
{{- $uris := .client.redirectUris | default list -}}
{{- if not $uris -}}
{{- $uris = list (printf "%s/*" (include "keycloak.loginUrl" .root)) -}}
{{- end -}}
{{- toJson $uris -}}
{{- end -}}

{{/* Web origins of a client: the values list, else https://login.<domain> */}}
{{- define "keycloak.clientWebOrigins" -}}
{{- $origins := .client.webOrigins | default list -}}
{{- if not $origins -}}
{{- $origins = list (include "keycloak.loginUrl" .root) -}}
{{- end -}}
{{- toJson $origins -}}
{{- end -}}
