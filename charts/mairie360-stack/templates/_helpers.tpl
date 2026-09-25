{{/*
Nom du chart.
*/}}
{{- define "mairie360.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Nom complet : <release>-<chart>, ou <release> si le release contient déjà le nom.
*/}}
{{- define "mairie360.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "mairie360.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mairie360.labels" -}}
helm.sh/chart: {{ include "mairie360.chart" . }}
{{ include "mairie360.selectorLabels" . }}
app.kubernetes.io/part-of: mairie360
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "mairie360.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mairie360.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Nom du Secret applicatif partagé (JWT_SECRET…).
*/}}
{{- define "mairie360.appSecretName" -}}
{{- default (printf "%s-app-secrets" .Release.Name) .Values.global.secrets.appSecretName -}}
{{- end }}

{{/*
Ingress controller of the instance (MAIR-260): "nginx" or "traefik", from
global.ingressController. Anything else fails the render rather than
producing an Ingress no controller serves.
*/}}
{{- define "mairie360.ingressController" -}}
{{- $c := .Values.global.ingressController | default "nginx" -}}
{{- if not (has $c (list "nginx" "traefik")) -}}
{{- fail (printf "global.ingressController must be \"nginx\" or \"traefik\", got %q" $c) -}}
{{- end -}}
{{- $c -}}
{{- end }}

{{/* IngressClass of the chart's Ingresses: ingress.className, else the controller. */}}
{{- define "mairie360.ingressClassName" -}}
{{- .Values.ingress.className | default (include "mairie360.ingressController" .) -}}
{{- end }}

{{/*
Namespace of the ingress controller (NetworkPolicies): global.ingressNamespace,
else the namespace the platform AppSet installs the controller into.
Same rule in charts/Fronts/templates/network-policy.yaml.
*/}}
{{- define "mairie360.ingressNamespace" -}}
{{- .Values.global.ingressNamespace | default (ternary "traefik" "ingress-nginx" (eq (include "mairie360.ingressController" .) "traefik")) -}}
{{- end }}

{{/* Name of the Traefik Middleware carrying the request body limit. */}}
{{- define "mairie360.ingressBodySizeMiddleware" -}}
{{- printf "%s-body-size" (include "mairie360.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
Annotations of an Ingress of the chart, as YAML. Translates the
controller-agnostic ingress.* values into the controller's own annotations,
then adds ingress.annotations (which win on a key conflict).
- both: cert-manager.io/cluster-issuer, and
  acme.cert-manager.io/http01-ingress-ingressclassname so that the HTTP-01
  solver Ingress uses this instance's class whatever the ClusterIssuer says
  (bootstrap/cluster-addons/cluster-issuers.yaml is shared by every instance);
- nginx: forced HTTPS redirect and proxy-body-size;
- traefik: routers on the websecure entrypoint only (the web entrypoint
  redirects to HTTPS, bootstrap/values/traefik.yaml) and the body-size
  Middleware (templates/traefik-middlewares.yaml).
*/}}
{{- define "mairie360.ingressAnnotations" -}}
{{- $controller := include "mairie360.ingressController" . -}}
{{- $annotations := dict -}}
{{- with .Values.ingress.clusterIssuer }}
{{- $_ := set $annotations "cert-manager.io/cluster-issuer" . -}}
{{- $_ := set $annotations "acme.cert-manager.io/http01-ingress-ingressclassname" (include "mairie360.ingressClassName" $) -}}
{{- end }}
{{- $maxBody := int (.Values.ingress.maxBodySizeMiB | default 0) -}}
{{- if eq $controller "traefik" }}
{{- $_ := set $annotations "traefik.ingress.kubernetes.io/router.entrypoints" "websecure" -}}
{{- $_ := set $annotations "traefik.ingress.kubernetes.io/router.tls" "true" -}}
{{- if gt $maxBody 0 }}
{{- $_ := set $annotations "traefik.ingress.kubernetes.io/router.middlewares" (printf "%s-%s@kubernetescrd" .Release.Namespace (include "mairie360.ingressBodySizeMiddleware" .)) -}}
{{- end }}
{{- else }}
{{- $_ := set $annotations "nginx.ingress.kubernetes.io/ssl-redirect" "true" -}}
{{- $_ := set $annotations "nginx.ingress.kubernetes.io/force-ssl-redirect" "true" -}}
{{- if gt $maxBody 0 }}
{{- $_ := set $annotations "nginx.ingress.kubernetes.io/proxy-body-size" (printf "%dm" $maxBody) -}}
{{- end }}
{{- end }}
{{- $annotations = merge (deepCopy (.Values.ingress.annotations | default dict)) $annotations -}}
{{- toYaml $annotations -}}
{{- end }}
