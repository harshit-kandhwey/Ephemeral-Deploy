#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Monitoring EC2 User Data - runs at instance launch
# Installs: Prometheus, Grafana, Node Exporter, CloudWatch Exporter
#
# Config files are stored in S3 (not inline) to stay within the 16KB
# EC2 user data limit. At boot this script downloads them from:
#   s3://${state_bucket}/monitoring/config/
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PROJECT="${project}"
ENVIRONMENT="${environment}"
AWS_REGION="${aws_region}"
ECS_CLUSTER="${ecs_cluster_name}"
GRAFANA_PASSWORD="${grafana_password}"
STATE_BUCKET="${state_bucket}"
CONFIG_PREFIX="monitoring/config"

exec > >(tee /var/log/monitoring-setup.log) 2>&1
echo "=== Monitoring setup started at $(date) ==="

# ── System updates ────────────────────────────────────────────────────────────
dnf update -y
dnf install -y wget curl jq

# ── Install Node Exporter ─────────────────────────────────────────────────────
NODEXP_VERSION="1.7.0"
wget -q https://github.com/prometheus/node_exporter/releases/download/v${NODEXP_VERSION}/node_exporter-${NODEXP_VERSION}.linux-amd64.tar.gz
tar xf node_exporter-${NODEXP_VERSION}.linux-amd64.tar.gz
mv node_exporter-${NODEXP_VERSION}.linux-amd64/node_exporter /usr/local/bin/
rm -rf node_exporter-${NODEXP_VERSION}*
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

# ── Install Prometheus ────────────────────────────────────────────────────────
PROM_VERSION="2.49.1"
wget -q https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz
tar xf prometheus-${PROM_VERSION}.linux-amd64.tar.gz
mv prometheus-${PROM_VERSION}.linux-amd64/prometheus /usr/local/bin/
mv prometheus-${PROM_VERSION}.linux-amd64/promtool   /usr/local/bin/
rm -rf prometheus-${PROM_VERSION}*
mkdir -p /etc/prometheus /var/lib/prometheus
useradd -rs /bin/false prometheus || true
chown prometheus:prometheus /var/lib/prometheus

cat > /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus
After=network.target cloudwatch_exporter.service
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

# ── Install CloudWatch Exporter ───────────────────────────────────────────────
CWE_VERSION="0.14.7"
wget -q https://github.com/prometheus/cloudwatch_exporter/releases/download/v${CWE_VERSION}/cloudwatch_exporter-${CWE_VERSION}.linux-amd64.tar.gz
tar xf cloudwatch_exporter-${CWE_VERSION}.linux-amd64.tar.gz
mv cloudwatch_exporter-${CWE_VERSION}.linux-amd64/cloudwatch_exporter /usr/local/bin/
rm -rf cloudwatch_exporter-${CWE_VERSION}*
useradd -rs /bin/false cloudwatch_exporter || true
mkdir -p /etc/cloudwatch_exporter
chown cloudwatch_exporter:cloudwatch_exporter /etc/cloudwatch_exporter

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

# ── Install Grafana ───────────────────────────────────────────────────────────
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

# ── Download configs from S3 ──────────────────────────────────────────────────
# Configs are stored in S3 to avoid the 16KB EC2 user data size limit.
# The EC2 IAM role grants s3:GetObject on s3://${state_bucket}/monitoring/*
echo "Downloading monitoring configs from s3://$STATE_BUCKET/$CONFIG_PREFIX/ ..."

mkdir -p /etc/grafana/provisioning/datasources
mkdir -p /etc/grafana/provisioning/dashboards
mkdir -p /var/lib/grafana/dashboards

aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/prometheus.yml"            /etc/prometheus/prometheus.yml          --region "$AWS_REGION"
aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/cloudwatch-exporter.yml"   /etc/cloudwatch_exporter/config.yml    --region "$AWS_REGION"
aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/grafana-datasources.yml"   /etc/grafana/provisioning/datasources/datasources.yml  --region "$AWS_REGION"
aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/grafana-dashboards.yml"    /etc/grafana/provisioning/dashboards/dashboards.yml    --region "$AWS_REGION"
aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/nexusdeploy-dashboard.json" /var/lib/grafana/dashboards/nexusdeploy.json          --region "$AWS_REGION"

echo "Configs downloaded successfully"

# ── Substitute placeholders in downloaded configs ─────────────────────────────
# Config files use NEXUSDEPLOY_* tokens instead of Terraform templatefile syntax
# so they can be stored as plain files in S3 (not .tpl files)
for f in \
  /etc/prometheus/prometheus.yml \
  /etc/cloudwatch_exporter/config.yml \
  /etc/grafana/provisioning/datasources/datasources.yml \
  /var/lib/grafana/dashboards/nexusdeploy.json; do
  sed -i \
    -e "s/NEXUSDEPLOY_PROJECT/$PROJECT/g" \
    -e "s/NEXUSDEPLOY_ENV/$ENVIRONMENT/g" \
    -e "s/NEXUSDEPLOY_REGION/$AWS_REGION/g" \
    -e "s/NEXUSDEPLOY_CLUSTER/$ECS_CLUSTER/g" \
    "$f"
done

# ── ECS Service Discovery script ──────────────────────────────────────────────
cat > /usr/local/bin/ecs-sd.sh << SDEOF
#!/bin/bash
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
  PRIVATE_IP=\$(echo "\$DETAILS" | jq -r '.attachments[0].details[] | select(.name=="privateIPv4Address") | .value' 2>/dev/null || echo "")
  TASK_DEF=\$(echo "\$DETAILS" | jq -r '.taskDefinitionArn' | awk -F'/' '{print \$NF}' | awk -F':' '{print \$1}' 2>/dev/null || echo "unknown")
  if [ -n "\$PRIVATE_IP" ]; then
    [ "\$FIRST" = false ] && TARGETS="\$TARGETS,"
    TARGETS="\$TARGETS{\"targets\":[\"\$PRIVATE_IP:5000\"],\"labels\":{\"job\":\"nexusdeploy-api\",\"task\":\"\$TASK_DEF\",\"env\":\"$ENVIRONMENT\"}}"
    FIRST=false
  fi
done
TARGETS="\$TARGETS]"
echo "\$TARGETS" > /etc/prometheus/ecs-targets.json
SDEOF
chmod +x /usr/local/bin/ecs-sd.sh
/usr/local/bin/ecs-sd.sh
echo "*/1 * * * * root /usr/local/bin/ecs-sd.sh" > /etc/cron.d/ecs-sd

# ── Grafana admin password ────────────────────────────────────────────────────
sed -i "s/^;admin_password = admin/admin_password = ${GRAFANA_PASSWORD}/" /etc/grafana/grafana.ini
sed -i "s/^admin_password = admin/admin_password = ${GRAFANA_PASSWORD}/"  /etc/grafana/grafana.ini
sed -i "s/;allow_sign_up = true/allow_sign_up = false/"                   /etc/grafana/grafana.ini

# ── Fix permissions ───────────────────────────────────────────────────────────
chown -R prometheus:prometheus /etc/prometheus
chown cloudwatch_exporter:cloudwatch_exporter /etc/cloudwatch_exporter/config.yml
chown -R grafana:grafana /var/lib/grafana/dashboards

# ── Start all services ────────────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable --now cloudwatch_exporter
systemctl enable --now node_exporter
systemctl enable --now prometheus
systemctl enable --now grafana-server

sleep 15
echo "=== Service Status ==="
systemctl is-active cloudwatch_exporter && echo "✅ cloudwatch_exporter running" || echo "❌ cloudwatch_exporter failed"
systemctl is-active node_exporter       && echo "✅ node_exporter running"       || echo "❌ node_exporter failed"
systemctl is-active prometheus          && echo "✅ prometheus running"           || echo "❌ prometheus failed"
systemctl is-active grafana-server      && echo "✅ grafana running"              || echo "❌ grafana failed"

PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
echo ""
echo "════════════════════════════════════════════"
echo " Monitoring Stack Ready!"
echo "════════════════════════════════════════════"
echo " Grafana:    http://$PUBLIC_IP:3000"
echo " Prometheus: http://$PUBLIC_IP:9090"
echo " Password:   (from SSM Parameter Store)"
echo "════════════════════════════════════════════"
echo "=== Setup complete at $(date) ==="
