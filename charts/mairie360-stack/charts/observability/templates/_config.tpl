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

service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [otlphttp/cockpit-traces]
    metrics:
      receivers: [otlp{{ if .Values.kubeletStats.enabled }}, kubeletstats{{ end }}]
      processors: [memory_limiter, filter/namespace, resource, batch]
      exporters: [otlphttp/cockpit-metrics]
{{- end -}}
