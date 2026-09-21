{{- define "backup.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "backup.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "backup.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" -}}
{{- end -}}

{{- define "backup.labels" -}}
helm.sh/chart: {{ include "backup.chart" . }}
{{ include "backup.selectorLabels" . }}
app.kubernetes.io/component: backup
app.kubernetes.io/part-of: mairie360
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "backup.selectorLabels" -}}
app.kubernetes.io/name: {{ include "backup.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "backup.podLabels" -}}
{{ include "backup.selectorLabels" . }}
app.kubernetes.io/component: backup
app.kubernetes.io/part-of: mairie360
{{- end -}}

{{/* Postgres superuser Secret, same one liquibase uses — pg_dump needs to
read every module's schema, which no single per-API role is granted. */}}
{{- define "backup.dbSecretName" -}}
{{- $g := .Values.global | default dict -}}
{{- $db := $g.database | default dict -}}
{{- $db.secretName | default (printf "%s-database-secret" .Release.Name) -}}
{{- end -}}

{{- define "backup.secretName" -}}
{{- .Values.secretName | default (printf "%s-secret" (include "backup.fullname" .)) -}}
{{- end -}}

{{/* restic repository URL: s3:<endpoint>/<bucket>. */}}
{{- define "backup.repository" -}}
{{- printf "s3:%s/%s" .Values.s3.endpoint .Values.s3.bucket -}}
{{- end -}}

{{/* Env shared by the backup CronJob and the restore Job: Postgres
connection (libpq reads PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE itself,
so pg_dump/pg_restore need no flags for them) plus the restic S3 repo. */}}
{{- define "backup.env" -}}
- name: PGHOST
  value: {{ printf "%s-database" .Release.Name | quote }}
- name: PGPORT
  value: {{ .Values.db.port | quote }}
- name: PGUSER
  valueFrom:
    secretKeyRef: { name: {{ include "backup.dbSecretName" . }}, key: POSTGRES_USER }
- name: PGPASSWORD
  valueFrom:
    secretKeyRef: { name: {{ include "backup.dbSecretName" . }}, key: POSTGRES_PASSWORD }
- name: PGDATABASE
  valueFrom:
    secretKeyRef: { name: {{ include "backup.dbSecretName" . }}, key: POSTGRES_DB }
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef: { name: {{ include "backup.secretName" . }}, key: AWS_ACCESS_KEY_ID }
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef: { name: {{ include "backup.secretName" . }}, key: AWS_SECRET_ACCESS_KEY }
- name: RESTIC_PASSWORD
  valueFrom:
    secretKeyRef: { name: {{ include "backup.secretName" . }}, key: RESTIC_PASSWORD }
- name: RESTIC_REPOSITORY
  value: {{ include "backup.repository" . | quote }}
- name: AWS_DEFAULT_REGION
  value: {{ .Values.s3.region | quote }}
{{- end -}}
