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
  {{- if .Values.usage.enabled }}
  # Usage ledgers of the APIs and BFFs (MAIR-501): closed periods, counts only.
  prometheus/usage:
    config:
      scrape_configs:
        - job_name: mairie360-usage
          scrape_interval: {{ .Values.usage.scrapeInterval | quote }}
          metrics_path: {{ .Values.usage.path | quote }}
          static_configs:
            - targets:
                {{- range required "observability.usage.services is required when observability.usage.enabled=true" .Values.usage.services }}
                - {{ printf "%s-%s:%v" $.Release.Name .name .port | quote }}
                {{- end }}
  {{- end }}
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
  # MAIR-501: a span keeps the allowlisted attributes only; everything that could carry a
  # person's data (user id, query string, body, client address, user agent) is dropped.
  transform/span-allowlist:
    error_mode: ignore
    trace_statements:
      - context: span
        statements:
          - keep_keys(span.attributes, [{{ range $i, $a := .Values.spanAttributesAllowlist }}{{ if $i }}, {{ end }}{{ $a | quote }}{{ end }}])
  {{- if .Values.usage.enabled }}
  # MAIR-501: only the ledger leaves (not the scrape's own up / scrape_* series), and a second
  # guard on the threshold in case a service exports a count under it. A Prometheus sample is a
  # double (value_int is then 0): the point is dropped when both values are under k.
  filter/usage-threshold:
    error_mode: ignore
    metrics:
      metric:
        - 'not IsMatch(name, "^mairie360_usage_")'
      datapoint:
        - 'IsMatch(metric.name, "^mairie360_usage_(actions|distinct_users)$") and value_double < {{ int .Values.usage.threshold }} and value_int < {{ int .Values.usage.threshold }}'
  # The scrape adds the target's address and job: neither belongs in the ledger.
  transform/usage-labels:
    error_mode: ignore
    metric_statements:
      - context: datapoint
        statements:
          - keep_keys(datapoint.attributes, ["service", "operation", "method", "status", "period_start"])
      - context: resource
        statements:
          - keep_keys(resource.attributes, ["deployment.environment.name", "service.namespace"])
    {{- with .Values.usage.export.mairie }}
          - set(resource.attributes["mairie360.mairie"], {{ . | quote }})
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
  {{- if and .Values.usage.enabled .Values.usage.export.enabled }}
  # Usage ledger towards Mairie 360 (MAIR-501): counts only, per mairie and per service.
  otlphttp/usage:
    metrics_endpoint: {{ required "observability.usage.export.endpoint is required when observability.usage.export.enabled=true" .Values.usage.export.endpoint | quote }}
  {{- end }}

service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, transform/span-allowlist, resource, batch]
      exporters: [otlphttp/cockpit-traces]
    metrics:
      receivers: [otlp{{ if .Values.kubeletStats.enabled }}, kubeletstats{{ end }}]
      processors: [memory_limiter, filter/namespace, resource, batch]
      exporters: [otlphttp/cockpit-metrics]
    {{- if .Values.usage.enabled }}
    metrics/usage:
      receivers: [prometheus/usage]
      processors: [memory_limiter, filter/usage-threshold, transform/usage-labels, resource, batch]
      exporters: [otlphttp/cockpit-metrics{{ if .Values.usage.export.enabled }}, otlphttp/usage{{ end }}]
    {{- end }}
{{- end -}}
