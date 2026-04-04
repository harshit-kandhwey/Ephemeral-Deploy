#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Monitoring EC2 User Data - runs at instance launch
# Installs: Prometheus, Grafana, Node Exporter
# Configures: ECS service discovery, CloudWatch datasource
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PROJECT="${project}"
ENVIRONMENT="${environment}"
AWS_REGION="${aws_region}"
ECS_CLUSTER="${ecs_cluster_name}"
GRAFANA_PASSWORD="${grafana_password}"

exec > >(tee /var/log/monitoring-setup.log) 2>&1
echo "=== Monitoring setup started at $(date) ==="

# ── System updates ────────────────────────────
dnf update -y
dnf install -y wget curl jq docker

# ── Install Node Exporter (system metrics) ───
NODEXP_VERSION="1.7.0"
wget -q https://github.com/prometheus/node_exporter/releases/download/v$${NODEXP_VERSION}/node_exporter-$${NODEXP_VERSION}.linux-amd64.tar.gz
tar xf node_exporter-$${NODEXP_VERSION}.linux-amd64.tar.gz
mv node_exporter-$${NODEXP_VERSION}.linux-amd64/node_exporter /usr/local/bin/
rm -rf node_exporter-$${NODEXP_VERSION}*

useradd -rs /bin/false node_exporter || true
cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ── Install Prometheus ────────────────────────
PROM_VERSION="2.49.1"
wget -q https://github.com/prometheus/prometheus/releases/download/v$${PROM_VERSION}/prometheus-$${PROM_VERSION}.linux-amd64.tar.gz
tar xf prometheus-$${PROM_VERSION}.linux-amd64.tar.gz
mv prometheus-$${PROM_VERSION}.linux-amd64/prometheus /usr/local/bin/
mv prometheus-$${PROM_VERSION}.linux-amd64/promtool   /usr/local/bin/
rm -rf prometheus-$${PROM_VERSION}*

mkdir -p /etc/prometheus /var/lib/prometheus
useradd -rs /bin/false prometheus || true
chown prometheus:prometheus /var/lib/prometheus

# ── Install CloudWatch Exporter ──────────────
# Downloads and installs prometheus/cloudwatch_exporter to export ECS metrics
CWE_VERSION="0.14.7"
wget -q https://github.com/prometheus/cloudwatch_exporter/releases/download/v$${CWE_VERSION}/cloudwatch_exporter-$${CWE_VERSION}.linux-amd64.tar.gz
tar xf cloudwatch_exporter-$${CWE_VERSION}.linux-amd64.tar.gz
mv cloudwatch_exporter-$${CWE_VERSION}.linux-amd64/cloudwatch_exporter /usr/local/bin/
rm -rf cloudwatch_exporter-$${CWE_VERSION}*

useradd -rs /bin/false cloudwatch_exporter || true
mkdir -p /etc/cloudwatch_exporter
chown cloudwatch_exporter:cloudwatch_exporter /etc/cloudwatch_exporter

# CloudWatch Exporter Configuration - exports ECS cluster and RDS metrics
cat > /etc/cloudwatch_exporter/config.yml << CWEEOF
region: $AWS_REGION
metrics:
  # ECS Cluster metrics
  - aws_namespace: AWS/ECS
    aws_metric_name: CPUUtilization
    aws_dimensions:
      ClusterName: [$ECS_CLUSTER]
      ServiceName: [nexusdeploy-$ENVIRONMENT-api, nexusdeploy-$ENVIRONMENT-worker]
    period_seconds: 300
    set_timestamp: false
    metrics:
      - name: ecs_cpu_utilization
        help: ECS service CPU utilization percentage
        type: gauge
  
  - aws_namespace: AWS/ECS
    aws_metric_name: MemoryUtilization
    aws_dimensions:
      ClusterName: [$ECS_CLUSTER]
      ServiceName: [nexusdeploy-$ENVIRONMENT-api, nexusdeploy-$ENVIRONMENT-worker]
    period_seconds: 300
    set_timestamp: false
    metrics:
      - name: ecs_memory_utilization
        help: ECS service memory utilization percentage
        type: gauge

  - aws_namespace: AWS/ECS
    aws_metric_name: DesiredTaskCount
    aws_dimensions:
      ClusterName: [$ECS_CLUSTER]
      ServiceName: [nexusdeploy-$ENVIRONMENT-api, nexusdeploy-$ENVIRONMENT-worker]
    period_seconds: 300
    set_timestamp: false
    metrics:
      - name: ecs_desired_task_count
        help: ECS service desired task count
        type: gauge

  - aws_namespace: AWS/ECS
    aws_metric_name: RunningTaskCount
    aws_dimensions:
      ClusterName: [$ECS_CLUSTER]
      ServiceName: [nexusdeploy-$ENVIRONMENT-api, nexusdeploy-$ENVIRONMENT-worker]
    period_seconds: 300
    set_timestamp: false
    metrics:
      - name: ecs_running_task_count
        help: ECS service running task count
        type: gauge

  # RDS metrics
  - aws_namespace: AWS/RDS
    aws_metric_name: CPUUtilization
    aws_dimensions:
      DBInstanceIdentifier: [nexusdeploy-$ENVIRONMENT-postgres]
    period_seconds: 300
    set_timestamp: false
    metrics:
      - name: rds_cpu_utilization
        help: RDS database CPU utilization percentage
        type: gauge

  - aws_namespace: AWS/RDS
    aws_metric_name: DatabaseConnections
    aws_dimensions:
      DBInstanceIdentifier: [nexusdeploy-$ENVIRONMENT-postgres]
    period_seconds: 300
    set_timestamp: false
    metrics:
      - name: rds_database_connections
        help: RDS active database connections
        type: gauge

  - aws_namespace: AWS/RDS
    aws_metric_name: FreeableMemory
    aws_dimensions:
      DBInstanceIdentifier: [nexusdeploy-$ENVIRONMENT-postgres]
    period_seconds: 300
    set_timestamp: false
    metrics:
      - name: rds_freeable_memory_bytes
        help: RDS available memory in bytes
        type: gauge
CWEEOF

chown cloudwatch_exporter:cloudwatch_exporter /etc/cloudwatch_exporter/config.yml

# CloudWatch Exporter Systemd Service
cat > /etc/systemd/system/cloudwatch_exporter.service << 'EOF'
[Unit]
Description=CloudWatch Exporter
After=network.target

[Service]
User=cloudwatch_exporter
ExecStart=/usr/local/bin/cloudwatch_exporter --config.file=/etc/cloudwatch_exporter/config.yml --listen-address=:9106
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ── ECS Service Discovery script ─────────────
# This script runs every 30 seconds and writes a targets file
# Prometheus reads this file to know which ECS task IPs to scrape
cat > /usr/local/bin/ecs-sd.sh << SDEOF
#!/bin/bash
# Discover ECS task private IPs and write Prometheus targets file
CLUSTER="$ECS_CLUSTER"
REGION="$AWS_REGION"

TASK_ARNS=\$(aws ecs list-tasks --cluster "\$CLUSTER" --region "\$REGION" --query 'taskArns[]' --output text 2>/dev/null || echo "")

if [ -z "\$TASK_ARNS" ]; then
  echo "[]" > /etc/prometheus/ecs-targets.json
  exit 0
fi

TARGETS="["
FIRST=true
for task_arn in \$TASK_ARNS; do
  DETAILS=\$(aws ecs describe-tasks --cluster "\$CLUSTER" --tasks "\$task_arn" --region "\$REGION" --query 'tasks[0]' --output json 2>/dev/null || echo "{}")
  
  # Get private IP from network interface
  PRIVATE_IP=\$(echo "\$DETAILS" | jq -r '.attachments[0].details[] | select(.name=="privateIPv4Address") | .value' 2>/dev/null || echo "")
  TASK_DEF=\$(echo "\$DETAILS" | jq -r '.taskDefinitionArn' | awk -F'/' '{print \$NF}' | awk -F':' '{print \$1}' 2>/dev/null || echo "unknown")
  
  if [ -n "\$PRIVATE_IP" ]; then
    [ "\$FIRST" = false ] && TARGETS="\$TARGETS,"
    TARGETS="\$TARGETS{\"targets\":[\"\\$PRIVATE_IP:5000\"],\"labels\":{\"job\":\"nexusdeploy-api\",\"task\":\"\$TASK_DEF\",\"env\":\"$ENVIRONMENT\"}}"
    FIRST=false
  fi
done
TARGETS="\$TARGETS]"

echo "\$TARGETS" > /etc/prometheus/ecs-targets.json
SDEOF
chmod +x /usr/local/bin/ecs-sd.sh

# Run discovery immediately and set up cron
/usr/local/bin/ecs-sd.sh
echo "*/1 * * * * root /usr/local/bin/ecs-sd.sh" > /etc/cron.d/ecs-sd

# ── Prometheus configuration ──────────────────
cat > /etc/prometheus/prometheus.yml << PROMEOF
global:
  scrape_interval:     15s
  evaluation_interval: 15s
  external_labels:
    project:     '$PROJECT'
    environment: '$ENVIRONMENT'
    region:      '$AWS_REGION'

# ─────────────────────────────────────────────
# Scrape configs
# ─────────────────────────────────────────────
scrape_configs:

  # Self-monitoring: Prometheus metrics
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # System metrics: this EC2 instance
  - job_name: 'node-exporter'
    static_configs:
      - targets: ['localhost:9100']
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        replacement: 'monitoring-ec2'

  # App metrics: NexusDeploy Flask API (ECS tasks)
  # Targets discovered dynamically via ecs-sd.sh script
  # Scrapes the /metrics endpoint which exposes Prometheus-format metrics
  - job_name: 'nexusdeploy-api'
    file_sd_configs:
      - files:
          - '/etc/prometheus/ecs-targets.json'
        refresh_interval: 30s
    metrics_path: '/metrics'
    scheme: http
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance

  # ECS cluster-level metrics via CloudWatch exporter
  # (shows understanding of hybrid scraping strategies)
  - job_name: 'cloudwatch-ecs'
    static_configs:
      - targets: ['localhost:9106']
    honor_labels: true
PROMEOF

chown -R prometheus:prometheus /etc/prometheus

cat > /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus
After=network.target cloudwatch_exporter.service
Requires=cloudwatch_exporter.service

[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=3d \
  --web.listen-address=0.0.0.0:9090 \
  --web.enable-lifecycle
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# ── Install Grafana ───────────────────────────
cat > /etc/yum.repos.d/grafana.repo << 'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF

dnf install -y grafana

# ── Grafana datasources (auto-provisioned) ────
mkdir -p /etc/grafana/provisioning/datasources
mkdir -p /etc/grafana/provisioning/dashboards
mkdir -p /var/lib/grafana/dashboards

cat > /etc/grafana/provisioning/datasources/datasources.yml << DSEOF
apiVersion: 1

datasources:
  # ── Prometheus datasource ──────────────────
  # For real-time app metrics scraped from Flask /metrics endpoint
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
    jsonData:
      timeInterval: "15s"

  # ── CloudWatch datasource ──────────────────
  # For AWS-managed metrics: RDS, ElastiCache, ECS, VPC Flow Logs
  # Uses EC2 instance role - no credentials needed
  - name: CloudWatch
    type: cloudwatch
    access: proxy
    jsonData:
      authType: ec2_iam_role
      defaultRegion: $AWS_REGION
      # CloudWatch Logs Insights for structured log queries
      logsTimeout: "30s"
DSEOF

# ── Dashboard provisioning config ────────────
cat > /etc/grafana/provisioning/dashboards/dashboards.yml << 'EOF'
apiVersion: 1

providers:
  - name: 'NexusDeploy'
    folder: 'NexusDeploy'
    type: file
    options:
      path: /var/lib/grafana/dashboards
EOF

# ── Pre-built Grafana dashboard ───────────────
cat > /var/lib/grafana/dashboards/nexusdeploy.json << DASHEOF
{
  "title": "NexusDeploy Overview",
  "uid": "nexusdeploy-overview",
  "tags": ["nexusdeploy", "ecs", "flask"],
  "time": { "from": "now-1h", "to": "now" },
  "refresh": "30s",
  "panels": [
    {
      "id": 1, "gridPos": {"x":0,"y":0,"w":6,"h":4},
      "type": "stat", "title": "HTTP Request Rate",
      "datasource": "Prometheus",
      "targets": [{ "expr": "rate(app_requests_total[5m])", "legendFormat": "req/s" }]
    },
    {
      "id": 2, "gridPos": {"x":6,"y":0,"w":6,"h":4},
      "type": "stat", "title": "p95 Request Latency",
      "datasource": "Prometheus",
      "targets": [{ "expr": "histogram_quantile(0.95, rate(app_request_latency_seconds_bucket[5m]))", "legendFormat": "p95" }]
    },
    {
      "id": 3, "gridPos": {"x":12,"y":0,"w":6,"h":4},
      "type": "stat", "title": "Error Rate (5xx)",
      "datasource": "Prometheus",
      "targets": [{ "expr": "rate(app_requests_total{status=~'5..'}[5m])", "legendFormat": "errors/s" }]
    },
    {
      "id": 4, "gridPos": {"x":18,"y":0,"w":6,"h":4},
      "type": "stat", "title": "ECS Running Tasks",
      "datasource": "CloudWatch",
      "targets": [{ "queryMode": "Metrics", "namespace": "AWS/ECS", "metricName": "RunningTaskCount", "dimensions": {} }]
    },
    {
      "id": 5, "gridPos": {"x":0,"y":4,"w":12,"h":8},
      "type": "timeseries", "title": "Request Latency Percentiles",
      "datasource": "Prometheus",
      "targets": [
        { "expr": "histogram_quantile(0.50, rate(app_request_latency_seconds_bucket[5m]))", "legendFormat": "p50" },
        { "expr": "histogram_quantile(0.95, rate(app_request_latency_seconds_bucket[5m]))", "legendFormat": "p95" },
        { "expr": "histogram_quantile(0.99, rate(app_request_latency_seconds_bucket[5m]))", "legendFormat": "p99" }
      ]
    },
    {
      "id": 6, "gridPos": {"x":12,"y":4,"w":12,"h":8},
      "type": "timeseries", "title": "RDS CPU & Connections (CloudWatch)",
      "datasource": "CloudWatch",
      "targets": [
        { "queryMode": "Metrics", "namespace": "AWS/RDS", "metricName": "CPUUtilization",      "dimensions": {"DBInstanceIdentifier": "$${PROJECT}-$${ENVIRONMENT}-postgres"} },
        { "queryMode": "Metrics", "namespace": "AWS/RDS", "metricName": "DatabaseConnections", "dimensions": {"DBInstanceIdentifier": "$${PROJECT}-$${ENVIRONMENT}-postgres"} }
      ]
    }
  ]
}
DASHEOF

# ── Grafana admin password ────────────────────
sed -i "s/^;admin_password = admin/admin_password = $${GRAFANA_PASSWORD}/" /etc/grafana/grafana.ini
sed -i "s/^admin_password = admin/admin_password = $${GRAFANA_PASSWORD}/" /etc/grafana/grafana.ini
# Disable signup (not a public instance)
sed -i "s/;allow_sign_up = true/allow_sign_up = false/" /etc/grafana/grafana.ini

chown -R grafana:grafana /var/lib/grafana/dashboards

# ── Start all services ────────────────────────
systemctl daemon-reload
systemctl enable --now cloudwatch_exporter
systemctl enable --now node_exporter
systemctl enable --now prometheus
systemctl enable --now grafana-server

# ── Wait and verify ───────────────────────────
sleep 15
echo "=== Service Status ==="
systemctl is-active cloudwatch_exporter && echo "✅ cloudwatch_exporter running" || echo "❌ cloudwatch_exporter failed"
systemctl is-active node_exporter  && echo "✅ node_exporter running" || echo "❌ node_exporter failed"
systemctl is-active prometheus      && echo "✅ prometheus running"    || echo "❌ prometheus failed"
systemctl is-active grafana-server  && echo "✅ grafana running"       || echo "❌ grafana failed"

PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
echo ""
echo "════════════════════════════════════════════"
echo " Monitoring Stack Ready!"
echo "════════════════════════════════════════════"
echo " Grafana:    http://$PUBLIC_IP:3000"
echo " Prometheus: http://$PUBLIC_IP:9090"
echo " User:       admin"
echo " Password:   (from SSM Parameter Store)"
echo "════════════════════════════════════════════"
echo "=== Setup complete at $(date) ==="
