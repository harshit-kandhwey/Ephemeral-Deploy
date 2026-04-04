#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Monitoring EC2 User Data
# Installs: Prometheus, Grafana, Node Exporter, YACE (CloudWatch Exporter)
#
# Security notes:
#   - Grafana password fetched from SSM at runtime (not embedded in user_data)
#   - Lifecycle API restricted by security group (port 9090 internal VPC only)
#   - Config files downloaded from S3 — not inline — to stay under 16KB limit
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PROJECT="${project}"
ENVIRONMENT="${environment}"
AWS_REGION="${aws_region}"
ECS_CLUSTER="${ecs_cluster_name}"
STATE_BUCKET="${state_bucket}"
CONFIG_PREFIX="monitoring/config"

# Fetch Grafana password from SSM at runtime.
# NOT embedded in user_data — avoids exposure in EC2 console and metadata service.
GRAFANA_PASSWORD=$(aws ssm get-parameter \
  --name "/${project}/${environment}/monitoring/grafana_password" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region "${aws_region}")

exec > >(tee /var/log/monitoring-setup.log) 2>&1
# Mask the password from logs immediately after fetching
echo "=== Monitoring setup started at $(date) ==="
echo "Project: $PROJECT | Environment: $ENVIRONMENT | Region: $AWS_REGION"

# ── System updates ────────────────────────────────────────────────────────────
dnf update -y
dnf install -y wget curl jq

# ── Install Node Exporter ─────────────────────────────────────────────────────
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

# ── Install Prometheus ────────────────────────────────────────────────────────
PROM_VERSION="2.49.1"
wget -q https://github.com/prometheus/prometheus/releases/download/v$${PROM_VERSION}/prometheus-$${PROM_VERSION}.linux-amd64.tar.gz
tar xf prometheus-$${PROM_VERSION}.linux-amd64.tar.gz
mv prometheus-$${PROM_VERSION}.linux-amd64/prometheus /usr/local/bin/
mv prometheus-$${PROM_VERSION}.linux-amd64/promtool   /usr/local/bin/
rm -rf prometheus-$${PROM_VERSION}*
mkdir -p /etc/prometheus /var/lib/prometheus
useradd -rs /bin/false prometheus || true
chown prometheus:prometheus /var/lib/prometheus

cat > /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus
After=network.target yace.service
[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=3d \
  --web.listen-address=0.0.0.0:9090 \
  --web.enable-lifecycle
# --web.enable-lifecycle allows /-/reload without restart.
# Port 9090 is restricted to VPC CIDR by the monitoring security group.
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

# ── Install YACE (Yet Another CloudWatch Exporter) ───────────────────────────
# prometheus/cloudwatch_exporter is a JAR — requires Java and has no binary release.
# YACE is the Go-based drop-in replacement with identical config format and binary dist.
# https://github.com/nerdswords/yet-another-cloudwatch-exporter
YACE_VERSION="0.61.2"
wget -q "https://github.com/nerdswords/yet-another-cloudwatch-exporter/releases/download/v$${YACE_VERSION}/yet-another-cloudwatch-exporter_$${YACE_VERSION}_Linux_x86_64.tar.gz"
tar xf yet-another-cloudwatch-exporter_$${YACE_VERSION}_Linux_x86_64.tar.gz
mv yet-another-cloudwatch-exporter /usr/local/bin/yace
rm -f yet-another-cloudwatch-exporter_$${YACE_VERSION}_Linux_x86_64.tar.gz
useradd -rs /bin/false yace || true
mkdir -p /etc/yace
chown yace:yace /etc/yace

cat > /etc/systemd/system/yace.service << 'EOF'
[Unit]
Description=YACE - Yet Another CloudWatch Exporter
After=network.target
[Service]
User=yace
ExecStart=/usr/local/bin/yace --config.file=/etc/yace/config.yml --listen-address=:9106
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
echo "Downloading monitoring configs from s3://$STATE_BUCKET/$CONFIG_PREFIX/ ..."

mkdir -p /etc/grafana/provisioning/datasources
mkdir -p /etc/grafana/provisioning/dashboards
mkdir -p /var/lib/grafana/dashboards

aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/prometheus.yml"             /etc/prometheus/prometheus.yml                                 --region "$AWS_REGION"
aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/cloudwatch-exporter.yml"   /etc/yace/config.yml                                           --region "$AWS_REGION"

aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/grafana-dashboards.yml"    /etc/grafana/provisioning/dashboards/dashboards.yml            --region "$AWS_REGION"
aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/grafana-datasources.yml"   /etc/grafana/provisioning/datasources/datasources.yml          --region "$AWS_REGION"
aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/nexusdeploy-dashboard.json" /var/lib/grafana/dashboards/nexusdeploy.json                  --region "$AWS_REGION"

echo "Configs downloaded successfully"

# ── Substitute placeholders in downloaded configs ─────────────────────────────
# Config files use NEXUSDEPLOY_* tokens. We escape special sed characters
# so values like region strings (containing hyphens) don't break substitution.
escape_sed() { printf '%s\n' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/\//\\\//g'; }

PROJECT_ESC=$(escape_sed "$PROJECT")
ENV_ESC=$(escape_sed "$ENVIRONMENT")
REGION_ESC=$(escape_sed "$AWS_REGION")
CLUSTER_ESC=$(escape_sed "$ECS_CLUSTER")

for f in \
  /etc/prometheus/prometheus.yml \
  /etc/yace/config.yml \
  /var/lib/grafana/dashboards/nexusdeploy.json; do
  sed -i \
    -e "s/NEXUSDEPLOY_PROJECT/$PROJECT_ESC/g" \
    -e "s/NEXUSDEPLOY_ENV/$ENV_ESC/g" \
    -e "s/NEXUSDEPLOY_REGION/$REGION_ESC/g" \
    -e "s/NEXUSDEPLOY_CLUSTER/$CLUSTER_ESC/g" \
    "$f"
done

echo "Placeholder substitution complete"

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
# Password was fetched from SSM at the top of this script (not embedded).
# Escape special sed characters in the password (/, &, \ can break sed syntax)
GRAFANA_PASSWORD_ESC=$(escape_sed "$GRAFANA_PASSWORD")
sed -i "s/^;admin_password = admin/admin_password = $${GRAFANA_PASSWORD_ESC}/" /etc/grafana/grafana.ini
sed -i "s/^admin_password = admin/admin_password = $${GRAFANA_PASSWORD_ESC}/"  /etc/grafana/grafana.ini
sed -i "s/;allow_sign_up = true/allow_sign_up = false/"                       /etc/grafana/grafana.ini

# ── Fix permissions ───────────────────────────────────────────────────────────
chown -R prometheus:prometheus /etc/prometheus
chown yace:yace /etc/yace/config.yml
chown -R grafana:grafana /var/lib/grafana/dashboards

# ── Start all services ────────────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable --now yace
systemctl enable --now node_exporter
systemctl enable --now prometheus
systemctl enable --now grafana-server

sleep 15
echo "=== Service Status ==="
systemctl is-active yace          && echo "✅ yace running"          || echo "❌ yace failed"
systemctl is-active node_exporter && echo "✅ node_exporter running" || echo "❌ node_exporter failed"
systemctl is-active prometheus    && echo "✅ prometheus running"    || echo "❌ prometheus failed"
systemctl is-active grafana-server && echo "✅ grafana running"      || echo "❌ grafana failed"

# IMDSv2 — required on instances with HttpTokens=required, resistant to SSRF
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token"   -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN"   http://169.254.169.254/latest/meta-data/public-ipv4)
echo ""
echo "════════════════════════════════════════════"
echo " Monitoring Stack Ready!"
echo "════════════════════════════════════════════"
echo " Grafana:    http://$PUBLIC_IP:3000"
echo " Prometheus: http://$PUBLIC_IP:9090"
echo " YACE:       http://$PUBLIC_IP:9106"
echo " Password:   (from SSM Parameter Store)"
echo "════════════════════════════════════════════"
echo "=== Setup complete at $(date) ==="
