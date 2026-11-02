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

{{/* Keycloak's own Secret (charts/keycloak), read only for KEYCLOAK_DB_PASSWORD. */}}
{{- define "backup.keycloakSecretName" -}}
{{- printf "%s-keycloak-secret" .Release.Name -}}
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
{{- if .Values.keycloak.enabled }}
- name: BACKUP_KEYCLOAK
  value: "true"
- name: KEYCLOAK_PGHOST
  value: {{ printf "%s-keycloak-db" .Release.Name | quote }}
- name: KEYCLOAK_PGPORT
  value: {{ .Values.keycloak.db.port | quote }}
- name: KEYCLOAK_PGUSER
  value: {{ .Values.keycloak.db.user | quote }}
- name: KEYCLOAK_PGPASSWORD
  valueFrom:
    secretKeyRef: { name: {{ include "backup.keycloakSecretName" . }}, key: KEYCLOAK_DB_PASSWORD }
- name: KEYCLOAK_PGDATABASE
  value: {{ .Values.keycloak.db.name | quote }}
{{- end -}}
{{- end -}}


{{/*
MAIR-414: restic comes from its pinned official image instead of an
unversioned `apk add` at every run, so the Job runs as the image's postgres
user (uid 70) on a read-only root filesystem. The initContainer copies the
static binary into an emptyDir; restic's cache and HOME go to emptyDirs too.
*/}}
{{- define "backup.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 70
runAsGroup: 70
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "backup.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end -}}

{{- define "backup.resticInit" -}}
- name: restic
  image: "{{ .Values.restic.image.repository }}:{{ .Values.restic.image.tag }}"
  imagePullPolicy: IfNotPresent
  command: ["cp", "/usr/bin/restic", "/tools/restic"]
  securityContext:
    {{- include "backup.containerSecurityContext" . | nindent 4 }}
  volumeMounts:
    - { name: tools, mountPath: /tools }
{{- end -}}

{{- define "backup.workEnv" -}}
- name: PATH
  value: "/tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
- name: HOME
  value: "/tmp"
- name: RESTIC_CACHE_DIR
  value: "/cache"
{{- end -}}

{{- define "backup.workMounts" -}}
- { name: tools, mountPath: /tools, readOnly: true }
- { name: cache, mountPath: /cache }
- { name: tmp, mountPath: /tmp }
{{- end -}}

{{- define "backup.workVolumes" -}}
- { name: tools, emptyDir: { sizeLimit: 64Mi } }
- { name: cache, emptyDir: { sizeLimit: 1Gi } }
- { name: tmp, emptyDir: { sizeLimit: 256Mi } }
{{- end -}}


{{/*
MAIR-500: sealed backups. The throwaway Postgres runs as a native sidecar
(initContainer with restartPolicy Always, Kubernetes >= 1.29), so the copy
and seal steps (initContainers) and the backup itself (main container) can
reach it on 127.0.0.1; trust authentication on the loopback only, the pod
admits nothing else (no Service, no port exposed).
*/}}
{{- define "backup.keyManagerEnv" -}}
{{- $km := ((.Values.global).compliance).keyManager | default dict }}
- name: SCW_SECRET_KEY
  valueFrom:
    secretKeyRef: { name: {{ include "backup.secretName" . }}, key: SCW_SECRET_KEY }
- name: SCW_DEFAULT_PROJECT_ID
  value: {{ required "global.compliance.keyManager.projectId is required when backup.sealing.enabled=true" $km.projectId | quote }}
- name: SCW_REGION
  value: {{ $km.region | default "fr-par" | quote }}
{{- end -}}

{{- define "backup.scratchDb" -}}
- name: scratch-db
  image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  restartPolicy: Always
  securityContext:
    {{- include "backup.containerSecurityContext" . | nindent 4 }}
  env:
    - { name: PGDATA, value: /scratch/pgdata }
    - { name: POSTGRES_HOST_AUTH_METHOD, value: trust }
  args: ["-c", "listen_addresses=127.0.0.1", "-c", "fsync=off"]
  startupProbe:
    exec: { command: ["pg_isready", "-h", "127.0.0.1", "-U", "postgres"] }
    periodSeconds: 2
    failureThreshold: 60
  volumeMounts:
    - { name: scratch, mountPath: /scratch }
    - { name: pgrun, mountPath: /var/run/postgresql }
    - { name: tmp, mountPath: /tmp }
{{- end -}}

{{- define "backup.sealVolumes" -}}
- { name: scratch, emptyDir: { sizeLimit: {{ .Values.sealing.scratchSize }} } }
- { name: work, emptyDir: { sizeLimit: {{ .Values.sealing.workSize }} } }
- { name: inventory, emptyDir: { sizeLimit: 16Mi } }
- { name: pgrun, emptyDir: { sizeLimit: 16Mi } }
{{- end -}}

{{- define "backup.inventoryInit" -}}
- name: inventory
  image: "{{ .Values.sealing.inventoryImage.repository }}:{{ required "backup.sealing.inventoryImage.tag is required when backup.sealing.enabled=true (the liquibase.image.tag of the instance)" .Values.sealing.inventoryImage.tag }}"
  imagePullPolicy: IfNotPresent
  command: ["cp", "/gdpr/inventory.yaml", "/inventory/inventory.yaml"]
  securityContext:
    {{- include "backup.containerSecurityContext" . | nindent 4 }}
  volumeMounts:
    - { name: inventory, mountPath: /inventory }
{{- end -}}

{{- define "backup.complianceImage" -}}
"{{ .Values.sealing.image.repository }}:{{ required "backup.sealing.image.tag is required when backup.sealing.enabled=true" .Values.sealing.image.tag }}"
{{- end -}}
