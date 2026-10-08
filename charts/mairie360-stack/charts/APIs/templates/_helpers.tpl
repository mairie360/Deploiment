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
{{- $c := ((.root.Values.global).compliance) | default dict -}}
{{- if and (eq .name "compliance-api") (not $g.port) -}}
{{- $g = dict "port" $c.port -}}
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

{{/* Postgres role name for an API instance key, e.g. "core-api" -> "core_api". */}}
{{- define "apis.dbRole" -}}
{{- . | replace "-" "_" -}}
{{- end }}

{{/* Secret key holding a role's password, e.g. "core-api" -> "CORE_API_PASSWORD". */}}
{{- define "apis.dbRolePasswordKey" -}}
{{- printf "%s_PASSWORD" (include "apis.dbRole" . | upper) -}}
{{- end }}

{{/*
Variables d'environnement injectées dans TOUTES les APIs.
Tous les secrets viennent de Secrets Kubernetes, jamais des values.
Prend un contexte { root, name } (name = l'instance courante, ex. "core-api") :
c'est aussi le nom du compte ACL Redis dédié à cette instance.
*/}}
{{- define "apis.commonEnv" -}}
- name: HOST
  value: "0.0.0.0"
- name: PORT
  value: "3000"
- name: DB_TYPE
  value: "postgres"
- name: DB_HOST
  value: {{ printf "%s-database" .root.Release.Name | quote }}
- name: DB_PORT
  value: "5432"
- name: DB_NAME
  valueFrom:
    secretKeyRef:
      name: {{ include "apis.dbSecretName" .root }}
      key: POSTGRES_DB
{{- /* MAIR-114: each API connects with its own Postgres role, never the
     postgres superuser (that stays reserved to Liquibase). An instance with
     no entry in global.database.roles gets no DB_USER/DB_PASSWORD at all
     rather than falling back to the superuser. */ -}}
{{- $dbRoles := ((.root.Values.global).database).roles | default list }}
{{- if (((.root.Values.global).compliance).enabled) }}
{{- $dbRoles = append $dbRoles "compliance-api" }}
{{- end }}
{{- if has .name $dbRoles }}
- name: DB_USER
  value: {{ include "apis.dbRole" .name | quote }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "apis.dbSecretName" .root }}
      key: {{ include "apis.dbRolePasswordKey" .name }}
{{- end }}
- name: REDIS_HOST
  value: {{ printf "%s-redis" .root.Release.Name | quote }}
- name: REDIS_PORT
  value: "6379"
- name: REDIS_USERNAME
  value: {{ .name | quote }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-redis" .root.Release.Name }}
      key: {{ printf "%s-password" .name }}
{{- /*
The APIs (API_lib `Redis::new`) only read REDIS_URL: the credentials must be
in it, or every command hits the disabled `default` account (NOAUTH).
Kubernetes expands $(VAR) from the variables defined ABOVE it in this list,
so the password never appears in the manifest. Passwords are hex
(scripts/seal-secrets.sh), hence URL-safe. MAIR-264.
*/}}
- name: REDIS_URL
  value: {{ printf "redis://$(REDIS_USERNAME):$(REDIS_PASSWORD)@%s-redis:6379" .root.Release.Name | quote }}
- name: JWT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "apis.appSecretName" .root }}
      key: JWT_SECRET
{{- include "apis.otelEnv" . }}
{{- include "apis.complianceEnv" . }}
{{- with .root.Values.commonEnv }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
MAIR-131: OpenTelemetry SDK settings (standard OTEL_* variables) for the APIs
listed in global.observability.apis, once global.observability.enabled turns
on the collector of the observability subchart. Its Service name
(<release>-otel-collector) is fixed there. K8S_POD_NAME must come before
OTEL_RESOURCE_ATTRIBUTES for the $(K8S_POD_NAME) expansion to work.
*/}}
{{- define "apis.otelEnv" -}}
{{- $o := (.root.Values.global).observability | default dict }}
{{- if and $o.enabled (has .name ($o.apis | default list)) }}
- name: OTEL_SERVICE_NAME
  value: {{ .name | quote }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ printf "http://%s-otel-collector:4318" .root.Release.Name | quote }}
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: "http/protobuf"
- name: K8S_POD_NAME
  valueFrom:
    fieldRef: { fieldPath: metadata.name }
- name: OTEL_RESOURCE_ATTRIBUTES
  value: {{ printf "k8s.namespace.name=%s,k8s.pod.name=$(K8S_POD_NAME)" .root.Release.Namespace | quote }}
{{- end }}
{{- end -}}

{{/*
MAIR-498: settings and erasure credentials of the compliance service, injected
into compliance-api ONLY: no other API gets the Keycloak admin client, the
Resend key or the S3 delete keys. Every secret key is optional: a connector
without its credentials stays "not configured" (Compliance_API CLAUDE.md).
Redis: the same ACL account scans and erases (redis chart, configmap.yaml).
*/}}
{{- define "apis.complianceSecretName" -}}
{{- $c := (.Values.global).compliance | default dict -}}
{{- $c.secretName | default (printf "%s-compliance-secret" .Release.Name) -}}
{{- end }}

{{- define "apis.complianceEnv" -}}
{{- $c := (.root.Values.global).compliance | default dict }}
{{- if and $c.enabled (eq .name "compliance-api") }}
{{- $kc := $c.keycloak | default dict }}
{{- $realm := ((.root.Values.global).keycloak).realm | default "mairie360" }}
{{- $kcBase := printf "http://%s-keycloak:8080" .root.Release.Name }}
{{- $secret := include "apis.complianceSecretName" .root }}
- name: SCAN_INTERVAL_SECONDS
  value: {{ $c.scanIntervalSeconds | default 21600 | quote }}
- name: ERASURE_RETRY_SECONDS
  value: {{ $c.erasureRetrySeconds | default 300 | quote }}
- name: REDIS_SCAN_URL
  value: "$(REDIS_URL)"
- name: REDIS_LONG_TTL_SECONDS
  value: {{ ($c.redis).longTtlSeconds | default 2592000 | quote }}
{{- with ($c.redis).erasurePatterns }}
- name: REDIS_ERASURE_URL
  value: "$(REDIS_URL)"
- name: REDIS_ERASURE_PATTERNS
  value: {{ join "," . | quote }}
{{- end }}
- name: KEYCLOAK_ADMIN_URL
  value: {{ $kc.adminUrl | default (printf "%s/admin/realms/%s" $kcBase $realm) | quote }}
- name: KEYCLOAK_TOKEN_URL
  value: {{ $kc.tokenUrl | default (printf "%s/realms/%s/protocol/openid-connect/token" $kcBase $realm) | quote }}
- name: KEYCLOAK_ADMIN_CLIENT_ID
  value: {{ $kc.adminClientId | default "compliance" | quote }}
- name: KEYCLOAK_ADMIN_CLIENT_SECRET
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: KEYCLOAK_ADMIN_CLIENT_SECRET, optional: true }
{{- with ($c.resend).audienceId }}
- name: RESEND_AUDIENCE_ID
  value: {{ . | quote }}
{{- end }}
- name: RESEND_API_KEY
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: RESEND_API_KEY, optional: true }
{{- with $c.s3 }}
{{- if .bucket }}
- name: S3_ENDPOINT
  value: {{ .endpoint | quote }}
- name: S3_REGION
  value: {{ .region | quote }}
- name: S3_ERASURE_BUCKET
  value: {{ .bucket | quote }}
- name: S3_ERASURE_PREFIX
  value: {{ .prefix | default "users/{user_id}/" | quote }}
{{- end }}
{{- end }}
- name: S3_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: S3_ACCESS_KEY_ID, optional: true }
- name: S3_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: S3_SECRET_ACCESS_KEY, optional: true }
{{- with ($c.keyManager).projectId }}
# MAIR-500: destroys the user's backup key at erasure.
- name: SCW_DEFAULT_PROJECT_ID
  value: {{ . | quote }}
- name: SCW_REGION
  value: {{ ($c.keyManager).region | default "fr-par" | quote }}
- name: SCW_SECRET_KEY
  valueFrom:
    secretKeyRef: { name: {{ $secret }}, key: SCW_SECRET_KEY, optional: true }
{{- end }}
{{- end }}
{{- end -}}
