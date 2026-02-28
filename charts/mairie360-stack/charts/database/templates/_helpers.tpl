{{/*
Nom du chart — utilisé pour identifier les ressources
*/}}
{{- define "database.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Nom complet — combine le nom du release et celui du chart
*/}}
{{- define "database.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Nom du chart + version (utile pour labels ou test)
*/}}
{{- define "database.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" -}}
{{- end -}}

{{/*
Labels communs pour toutes les ressources du chart
*/}}
{{- define "database.labels" -}}
helm.sh/chart: {{ include "database.chart" . }}
app.kubernetes.io/name: {{ include "database.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels — utilisés pour les matchLabels dans le Deployment
*/}}
{{- define "database.selectorLabels" -}}
app.kubernetes.io/name: {{ include "database.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
