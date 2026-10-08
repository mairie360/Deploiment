{{/*
Collector configuration. The Cockpit token is read from the env
(${env:COCKPIT_TOKEN}), never written into the ConfigMap.
*/}}
{{- define "observability.config" -}}
{{- $metricsEndpoint := required "observability.cockpit.metricsEndpoint is required when global.observability.enabled=true" .Values.cockpit.metricsEndpoint -}}
{{- $tracesEndpoint := required "observability.cockpit.tracesEndpoint is required when global.observability.enabled=true" .Values.cockpit.tracesEndpoint -}}
extensions:
  health_check:
    endpoint: "0.0.0.0:13133"

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:4317"
      http:
        endpoint: "0.0.0.0:4318"
  {{- if .Values.kubeletStats.enabled }}
  kubeletstats:
    collection_interval: {{ .Values.kubeletStats.collectionInterval | quote }}
    auth_type: serviceAccount
    endpoint: "https://${env:K8S_NODE_IP}:10250"
    insecure_skip_verify: {{ .Values.kubeletStats.insecureSkipVerify }}
    metric_groups: [pod, container]
  {{- end }}

processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: {{ .Values.memoryLimiter.limitPercentage }}
    spike_limit_percentage: {{ .Values.memoryLimiter.spikeLimitPercentage }}
  # The kubelet reports every pod of the node (kube-system, argocd agents...):
  # only this instance's namespace is worth paying Cockpit ingestion for.
  # Metrics without the attribute (OTLP from the apps) are kept.
  filter/namespace:
    error_mode: ignore
    metrics:
      metric:
        - 'resource.attributes["k8s.namespace.name"] != nil and resource.attributes["k8s.namespace.name"] != "{{ .Release.Namespace }}"'
  # Lets Grafana tell dev / staging / prod apart in a shared Cockpit project.
  resource:
    attributes:
      - key: deployment.environment.name
        value: {{ .Release.Name | quote }}
        action: insert
      - key: service.namespace
        value: "mairie360"
        action: insert
  batch: {}
  {{- if .Values.logMasking.enabled }}
  # MAIR-498: masking of personal data (values `logMasking`, a copy of
  # Compliance_API's masking-patterns.yaml). Each OTTL string escapes `\` and
  # `"`, and `$` is doubled for the collector's env expansion.
  transform/mask-personal-data:
    error_mode: ignore
    log_statements:
      - context: log
        statements:
          {{- range .Values.logMasking.patterns }}
          {{- $re := include "observability.ottlString" .regex }}
          {{- $rep := include "observability.ottlString" .replacement }}
          - {{ printf "replace_pattern(body, \"%s\", \"%s\")" $re $rep | toJson }}
          - {{ printf "replace_all_patterns(attributes, \"value\", \"%s\", \"%s\")" $re $rep | toJson }}
          {{- end }}
    trace_statements:
      - context: span
        statements:
          {{- range .Values.logMasking.patterns }}
          {{- $re := include "observability.ottlString" .regex }}
          {{- $rep := include "observability.ottlString" .replacement }}
          - {{ printf "replace_all_patterns(attributes, \"value\", \"%s\", \"%s\")" $re $rep | toJson }}
          {{- end }}
  {{- end }}

exporters:
  otlphttp/cockpit-metrics:
    # Full URL: `endpoint` would append /v1/metrics after Cockpit's /otlp/v1/metrics.
    metrics_endpoint: {{ $metricsEndpoint | quote }}
    headers:
      X-TOKEN: "${env:COCKPIT_TOKEN}"
  otlphttp/cockpit-traces:
    traces_endpoint: {{ $tracesEndpoint | quote }}
    headers:
      X-TOKEN: "${env:COCKPIT_TOKEN}"
  {{- with .Values.cockpit.logsEndpoint }}
  otlphttp/cockpit-logs:
    logs_endpoint: {{ . | quote }}
    headers:
      X-TOKEN: "${env:COCKPIT_TOKEN}"
  {{- end }}

service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter{{ if .Values.logMasking.enabled }}, transform/mask-personal-data{{ end }}, resource, batch]
      exporters: [otlphttp/cockpit-traces]
    {{- if .Values.cockpit.logsEndpoint }}
    logs:
      receivers: [otlp]
      processors: [memory_limiter{{ if .Values.logMasking.enabled }}, transform/mask-personal-data{{ end }}, resource, batch]
      exporters: [otlphttp/cockpit-logs]
    {{- end }}
    metrics:
      receivers: [otlp{{ if .Values.kubeletStats.enabled }}, kubeletstats{{ end }}]
      processors: [memory_limiter, filter/namespace, resource, batch]
      exporters: [otlphttp/cockpit-metrics]
{{- end -}}


{{/* A raw string as the inside of an OTTL "..." literal, `$` doubled for the
     collector's ${env:...} expansion (MAIR-498). */}}
{{- define "observability.ottlString" -}}
{{- . | replace "\\" "\\\\" | replace "\"" "\\\"" | replace "$" "$$" -}}
{{- end -}}
