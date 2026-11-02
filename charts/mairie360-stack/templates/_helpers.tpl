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
Public hostname of Keycloak (MAIR-139): global.keycloak.hostname, else
auth.<global.domain>. Same rule as "keycloak.hostname" in charts/keycloak,
which builds KC_HOSTNAME from it — the two must stay identical.
*/}}
{{- define "mairie360.keycloakHost" -}}
{{- .Values.global.keycloak.hostname | default (printf "auth.%s" (required "global.domain is required for the Keycloak Ingress" .Values.global.domain)) -}}
{{- end }}

{{/* Instance realm (MAIR-139): global.keycloak.realm, same rule as "keycloak.realmName" in charts/keycloak. */}}
{{- define "mairie360.keycloakRealm" -}}
{{- .Values.global.keycloak.realm | default "mairie360" -}}
{{- end }}

{{/*
Paths routed to Keycloak on auth.<domain> (MAIR-610), as a JSON list of
{path, pathType}. Each `keycloak.ingress.paths` entry is either a string (a
Prefix path) or {path, pathType: Exact|Prefix}; `path` goes through `tpl`, so
the values derive it from the realm name.
The render fails on a path that would expose what MAIR-610 closed:
- a Prefix path must end with "/": Traefik matches Prefix as a plain string
  prefix, so "/realms/x/account" would also route "/realms/x/accountfoo";
- any realm but global.keycloak.realm (the `master` realm first: Keycloak's
  super-admin sign-in), the admin console and REST API (/admin), the
  management endpoints (/metrics, /health: port 9000, never routed anyway) and
  the realm's `userinfo` endpoint, nor any Prefix path above one of them
  ("/", "/realms/", "/realms/<realm>/", ".../openid-connect/").
*/}}
{{- define "mairie360.keycloakIngressPaths" -}}
{{- $realm := include "mairie360.keycloakRealm" . -}}
{{- $realmPrefix := printf "/realms/%s/" $realm -}}
{{- $closed := list "/admin" "/metrics" "/health" "/realms/master" (printf "%sprotocol/openid-connect/userinfo" $realmPrefix) -}}
{{- $paths := list -}}
{{- range (required "keycloak.ingress.paths must list what auth.<domain> exposes" ((.Values.keycloak).ingress).paths) -}}
{{- $entry := . -}}
{{- if kindIs "string" . -}}
{{- $entry = dict "path" . -}}
{{- end -}}
{{- $path := tpl (required "keycloak.ingress.paths: every entry needs a path" $entry.path) $ -}}
{{- $type := $entry.pathType | default "Prefix" -}}
{{- if not (has $type (list "Exact" "Prefix")) -}}
{{- fail (printf "keycloak.ingress.paths: pathType of %q must be Exact or Prefix, got %q" $path $type) -}}
{{- end -}}
{{- if not (hasPrefix "/" $path) -}}
{{- fail (printf "keycloak.ingress.paths: %q must start with /" $path) -}}
{{- end -}}
{{- if and (eq $type "Prefix") (not (hasSuffix "/" $path)) -}}
{{- fail (printf "keycloak.ingress.paths: Prefix path %q must end with / (Traefik would also match %s<anything>); use pathType Exact for a single URL" $path $path) -}}
{{- end -}}
{{- if and (hasPrefix "/realms/" $path) (not (hasPrefix $realmPrefix $path)) -}}
{{- fail (printf "keycloak.ingress.paths: %q is outside the instance realm %q: no other realm (master first) is routed (MAIR-610)" $path $realmPrefix) -}}
{{- end -}}
{{- range $closed -}}
{{- if or (hasPrefix . $path) (and (eq $type "Prefix") (hasPrefix $path .)) -}}
{{- fail (printf "keycloak.ingress.paths: %q would route %s, which stays closed to the Internet (MAIR-414, MAIR-610)" $path .) -}}
{{- end -}}
{{- end -}}
{{- $paths = append $paths (dict "path" $path "pathType" $type) -}}
{{- end -}}
{{- toJson $paths -}}
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
