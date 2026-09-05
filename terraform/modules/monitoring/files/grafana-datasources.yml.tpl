apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    jsonData:
      timeInterval: "15s"

  - name: CloudWatch
    type: cloudwatch
    access: proxy
    jsonData:
      authType: ec2_iam_role
      defaultRegion: ${aws_region}
      logsTimeout: "30s"

  # Jaeger is a core Grafana datasource, no plugin install needed. Same
  # instance, so localhost — see docs/design-decisions.md#self-hosted-tracing-otel-collector--jaeger-not-x-ray.
  - name: Jaeger
    type: jaeger
    access: proxy
    url: http://localhost:16686
