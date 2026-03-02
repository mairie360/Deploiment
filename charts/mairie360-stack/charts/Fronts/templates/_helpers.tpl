{{/* Nom complet avec force minuscules */}}
{{- define "fronts.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | lower | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Nom complet en minuscules */}}
{{- define "fronts.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | lower | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels pour le matching NetworkPolicy */}}
{{- define "fronts.labels" -}}
app: fronts
component: frontend
release: {{ .Release.Name }}
{{- end -}}

{{/* Configuration commune pour pointer vers les BFFs */}}
{{- define "fronts.commonEnv" -}}
- name: PORT
  value: "80"
- name: USER_BFF_URL
  value: {{ printf "http://%s-bff-user:4000" .Release.Name | quote }}
  {{- end -}}