{{- define "database.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "database.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "database.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" -}}
{{- end -}}

{{- define "database.labels" -}}
helm.sh/chart: {{ include "database.chart" . }}
{{ include "database.selectorLabels" . }}
app.kubernetes.io/component: database
app.kubernetes.io/part-of: mairie360
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Sélecteur immuable (StatefulSet) : inchangé par rapport à la v0.1. */}}
{{- define "database.selectorLabels" -}}
app: {{ include "database.name" . }}
{{- end -}}

{{- define "database.podLabels" -}}
{{ include "database.selectorLabels" . }}
app.kubernetes.io/name: {{ include "database.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: database
app.kubernetes.io/part-of: mairie360
{{- end -}}

{{- define "database.secretName" -}}
{{- $g := .Values.global | default dict -}}
{{- $db := $g.database | default dict -}}
{{- $db.secretName | default (printf "%s-secret" (include "database.fullname" .)) -}}
{{- end -}}

{{/* Postgres role name for an API instance key, e.g. "core-api" -> "core_api". */}}
{{- define "database.roleName" -}}
{{- . | replace "-" "_" -}}
{{- end -}}

{{/* Secret key holding a role's password, e.g. "core-api" -> "CORE_API_PASSWORD". */}}
{{- define "database.rolePasswordKey" -}}
{{- printf "%s_PASSWORD" (include "database.roleName" . | upper) -}}
{{- end -}}

{{/* CloudNativePG Cluster of a generation: <release>-database-g<n>. */}}
{{- define "database.cnpgClusterName" -}}
{{- printf "%s-g%d" (include "database.fullname" .root) (int .generation) -}}
{{- end -}}

{{- define "database.cnpgCurrentCluster" -}}
{{- include "database.cnpgClusterName" (dict "root" . "generation" .Values.cnpg.generation) -}}
{{- end -}}

{{- define "database.cnpgDatabaseName" -}}
{{- .Values.cnpg.databaseName | default (printf "mairie_db_%s" .Release.Name) -}}
{{- end -}}

{{- define "database.cnpgSuperuserSecret" -}}
{{- .Values.cnpg.superuserSecretName | default (printf "%s-superuser" (include "database.fullname" .)) -}}
{{- end -}}

{{- define "database.cnpgObjectStore" -}}
{{- printf "%s-backups" (include "database.fullname" .) -}}
{{- end -}}

{{- define "database.cnpgBackupSecret" -}}
{{- .Values.cnpg.backup.credentialsSecretName | default (printf "%s-backup-secret" .Release.Name) -}}
{{- end -}}

{{/* Labels of the CloudNativePG pods. Never `app: database`: that is the
     StatefulSet's selector, and the client Service must not reach both
     engines while they run side by side. */}}
{{- define "database.cnpgPodLabels" -}}
app.kubernetes.io/name: {{ include "database.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: database
app.kubernetes.io/part-of: mairie360
{{- end -}}

{{/* Fails the render on an inconsistent engine / bootstrap setting. */}}
{{- define "database.validate" -}}
{{- $engine := .Values.engine -}}
{{- if not (has $engine (list "statefulset" "cnpg")) -}}
{{- fail (printf "database.engine must be statefulset or cnpg, not %q" $engine) -}}
{{- end -}}
{{- if and (eq $engine "statefulset") (not .Values.statefulset.enabled) -}}
{{- fail "database.engine=statefulset needs database.statefulset.enabled" -}}
{{- end -}}
{{- if and (eq $engine "cnpg") (not .Values.cnpg.enabled) -}}
{{- fail "database.engine=cnpg needs database.cnpg.enabled" -}}
{{- end -}}
{{- if not (or .Values.statefulset.enabled .Values.cnpg.enabled) -}}
{{- fail "database: enable the StatefulSet, CloudNativePG or both" -}}
{{- end -}}
{{- if .Values.cnpg.enabled -}}
{{- $mode := .Values.cnpg.bootstrap -}}
{{- if not (has $mode (list "initdb" "import" "recovery")) -}}
{{- fail (printf "database.cnpg.bootstrap must be initdb, import or recovery, not %q" $mode) -}}
{{- end -}}
{{- if lt (int .Values.cnpg.generation) 1 -}}
{{- fail "database.cnpg.generation starts at 1" -}}
{{- end -}}
{{- if eq $mode "recovery" -}}
{{- $from := int (.Values.cnpg.recovery.fromGeneration | default (sub (int .Values.cnpg.generation) 1)) -}}
{{- if or (lt $from 1) (ge $from (int .Values.cnpg.generation)) -}}
{{- fail "database.cnpg.bootstrap=recovery restores an older generation: bump database.cnpg.generation, recovery.fromGeneration must be below it" -}}
{{- end -}}
{{- if not .Values.cnpg.backup.enabled -}}
{{- fail "database.cnpg.bootstrap=recovery reads the backups: database.cnpg.backup must be enabled" -}}
{{- end -}}
{{- end -}}
{{- if .Values.cnpg.backup.enabled -}}
{{- if not (and .Values.cnpg.backup.s3.endpoint .Values.cnpg.backup.s3.bucket) -}}
{{- fail "database.cnpg.backup needs s3.endpoint and s3.bucket (the instance's backup bucket)" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Labels of the CloudNativePG objects: those of the chart without the
     StatefulSet's `app` selector label. */}}
{{- define "database.cnpgLabels" -}}
helm.sh/chart: {{ include "database.chart" . }}
{{ include "database.cnpgPodLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
