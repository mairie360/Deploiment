{{/* Template pour les variables d'environnement communes (Postgres + Redis) */}}
{{- define "apis.commonEnv" -}}
- name: HOST
  value: "0.0.0.0"
- name: PORT
  value: "3000"
- name: DB_TYPE
  value: "postgres"
- name: DB_NAME
  value: "mairie_360_database"
- name: DB_HOST
  value: {{ printf "%s-database" .Release.Name | quote }}
- name: DB_PORT
  value: "5432"
- name: DB_USER
  value: "postgres"
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-database" .Release.Name }}
      key: postgres-password
- name: REDIS_URL
  value: {{ printf "redis://%s-redis:6379" .Release.Name | quote }}
{{- end -}}

{{/* Labels pour le sélecteur */}}
{{- define "apis.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
component: api
{{- end -}}