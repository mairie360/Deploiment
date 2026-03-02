{{/* Env pour les BFFs : Connexion aux APIs et Redis uniquement */}}
{{- define "bffs.commonEnv" -}}
- name: PORT
  value: "4000"
- name: NODE_ENV
  value: "production"

{{/* URL de l'API Core (interne au cluster) */}}
- name: CORE_API_URL
  value: {{ printf "http://%s-core-api:3000" .Release.Name | quote }}

{{/* Connexion Redis (pour les sessions/cache) */}}
- name: REDIS_HOST
  value: {{ printf "%s-redis" .Release.Name | quote }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ printf "%s-redis" .Release.Name }}
      key: redis-password
{{- end -}}