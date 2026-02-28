{{/* Template pour les variables d'environnement communes (Postgres + Redis) */}}
{{- define "apis.commonEnv" -}}
- name: HOST
  value: "0.0.0.0"
- name: PORT
  value: "3000"
- name: DB_TYPE
  value: "postgres"
- name: DB_HOST
  value: {{ printf "%s-database" .Release.Name | quote }}
- name: DB_PORT
  value: "5432"

{{/* --- POSTGRES SECRETS --- */}}
- name: DB_NAME
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-database-secret" .Release.Name }}
      key: POSTGRES_DB
- name: DB_USER
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-database-secret" .Release.Name }}
      key: POSTGRES_USER
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-database-secret" .Release.Name }}
      key: POSTGRES_PASSWORD

{{/* --- REDIS CONFIG --- */}}
- name: REDIS_HOST
  value: {{ printf "%s-redis" .Release.Name | quote }}
- name: REDIS_PORT
  value: "6379"
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-redis" .Release.Name }}
      key: redis-password

{{/* URL formatée pour les libs qui préfèrent une chaîne complète (ex: redis://:password@host:port) */}}
- name: REDIS_URL
  value: {{ printf "redis://:%s-redis:6379" .Release.Name | quote }}
  # Note : Si ton code a besoin du mot de passe DANS l'URL, il faudra le gérer 
  # au niveau applicatif via REDIS_PASSWORD pour des raisons de sécurité K8s.
{{- end -}}