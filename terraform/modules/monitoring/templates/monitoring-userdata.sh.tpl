#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Monitoring EC2 User Data — Ubuntu 24.04
# Installs: Prometheus, Grafana, Node Exporter, YACE (CloudWatch Exporter)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

exec > >(tee /var/log/monitoring-setup.log) 2>&1
echo "=== Monitoring setup started at $(date) ==="

PROJECT="${project}"
ENVIRONMENT="${environment}"
AWS_REGION="${aws_region}"
ECS_CLUSTER="${ecs_cluster_name}"
STATE_BUCKET="${state_bucket}"
CONFIG_PREFIX="monitoring/config"

echo "Project: $PROJECT | Environment: $ENVIRONMENT | Region: $AWS_REGION"

# ── System packages (awscli needed before SSM fetch) ─────────────────────────
echo "Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wget curl jq unzip awscli
echo "✅ System packages installed"

# ── Fetch Grafana password from SSM ──────────────────────────────────────────
echo "Fetching Grafana password from SSM..."
GRAFANA_PASSWORD=$(aws ssm get-parameter \
  --name "/$PROJECT/$ENVIRONMENT/monitoring/grafana_password" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region "$AWS_REGION") || { echo "❌ Failed to fetch Grafana password"; exit 1; }
echo "✅ Grafana password fetched"

# ── Download binaries to /tmp ─────────────────────────────────────────────────
cd /tmp

# ── Install Node Exporter ─────────────────────────────────────────────────────
echo "Installing Node Exporter..."
NODEXP_VERSION="1.7.0"
wget -q "https://github.com/prometheus/node_exporter/releases/download/v$${NODEXP_VERSION}/node_exporter-$${NODEXP_VERSION}.linux-amd64.tar.gz"
tar xf "node_exporter-$${NODEXP_VERSION}.linux-amd64.tar.gz"
mv "node_exporter-$${NODEXP_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
rm -rf "node_exporter-$${NODEXP_VERSION}"* 
useradd -rs /bin/false node_exporter 2>/dev/null || true
cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Node Exporter
After=network.target
[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
echo "✅ Node Exporter installed"

# ── Install Prometheus ────────────────────────────────────────────────────────
echo "Installing Prometheus..."
PROM_VERSION="2.49.1"
wget -q "https://github.com/prometheus/prometheus/releases/download/v$${PROM_VERSION}/prometheus-$${PROM_VERSION}.linux-amd64.tar.gz"
tar xf "prometheus-$${PROM_VERSION}.linux-amd64.tar.gz"
mv "prometheus-$${PROM_VERSION}.linux-amd64/prometheus" /usr/local/bin/
mv "prometheus-$${PROM_VERSION}.linux-amd64/promtool"   /usr/local/bin/
rm -rf "prometheus-$${PROM_VERSION}"*
mkdir -p /etc/prometheus /var/lib/prometheus
useradd -rs /bin/false prometheus 2>/dev/null || true
chown prometheus:prometheus /var/lib/prometheus
cat > /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus
After=network.target
[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=3d \
  --web.listen-address=0.0.0.0:9090 \
  --web.enable-lifecycle
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
echo "✅ Prometheus installed"

# ── Install YACE ──────────────────────────────────────────────────────────────
echo "Installing YACE..."
YACE_VERSION="0.61.2"
wget -q "https://github.com/nerdswords/yet-another-cloudwatch-exporter/releases/download/v$${YACE_VERSION}/yet-another-cloudwatch-exporter_$${YACE_VERSION}_Linux_x86_64.tar.gz"
tar xf "yet-another-cloudwatch-exporter_$${YACE_VERSION}_Linux_x86_64.tar.gz"
# Binary may be named 'yace' or 'yet-another-cloudwatch-exporter' depending on version
mv yet-another-cloudwatch-exporter /usr/local/bin/yace 2>/dev/null || \
  mv yace /usr/local/bin/yace 2>/dev/null || \
  { echo "❌ Could not find YACE binary in tarball"; ls -la; exit 1; }
rm -f "yet-another-cloudwatch-exporter_$${YACE_VERSION}_Linux_x86_64.tar.gz"
useradd -rs /bin/false yace 2>/dev/null || true
mkdir -p /etc/yace
chown yace:yace /etc/yace
cat > /etc/systemd/system/yace.service << 'EOF'
[Unit]
Description=YACE CloudWatch Exporter
After=network.target
[Service]
User=yace
ExecStart=/usr/local/bin/yace --config.file=/etc/yace/config.yml --listen-address=:9106
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
echo "✅ YACE installed"

# ── Install Grafana via apt (resolves deps automatically) ─────────────────────
echo "Installing Grafana..."
wget -q -O /tmp/grafana.deb "https://dl.grafana.com/oss/release/grafana_11.4.0_amd64.deb"
apt-get install -y -qq /tmp/grafana.deb
rm -f /tmp/grafana.deb
echo "✅ Grafana installed"

# ── Download configs from S3 ──────────────────────────────────────────────────
echo "Downloading configs from S3..."
mkdir -p /etc/prometheus /etc/yace \
  /etc/grafana/provisioning/datasources \
  /etc/grafana/provisioning/dashboards \
  /var/lib/grafana/dashboards

aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/prometheus.yml"             /etc/prometheus/prometheus.yml                        --region "$AWS_REGION"
aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/cloudwatch-exporter.yml"   /etc/yace/config.yml                                  --region "$AWS_REGION"
aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/grafana-datasources.yml"   /etc/grafana/provisioning/datasources/datasources.yml --region "$AWS_REGION"
aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/grafana-dashboards.yml"    /etc/grafana/provisioning/dashboards/dashboards.yml   --region "$AWS_REGION"
aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/nexusdeploy-dashboard.json" /var/lib/grafana/dashboards/nexusdeploy.json         --region "$AWS_REGION"
echo "✅ Configs downloaded"

# ── Substitute placeholders ───────────────────────────────────────────────────
escape_sed() { printf '%s\n' "$1" | sed -e 's/[\/&]/\\&/g'; }
PROJECT_ESC=$(escape_sed "$PROJECT")
ENV_ESC=$(escape_sed "$ENVIRONMENT")
REGION_ESC=$(escape_sed "$AWS_REGION")
CLUSTER_ESC=$(escape_sed "$ECS_CLUSTER")

for f in /etc/prometheus/prometheus.yml /etc/yace/config.yml /var/lib/grafana/dashboards/nexusdeploy.json; do
  sed -i \
    -e "s/NEXUSDEPLOY_PROJECT/$PROJECT_ESC/g" \
    -e "s/NEXUSDEPLOY_ENV/$ENV_ESC/g" \
    -e "s/NEXUSDEPLOY_REGION/$REGION_ESC/g" \
    -e "s/NEXUSDEPLOY_CLUSTER/$CLUSTER_ESC/g" \
    "$f"
done
echo "✅ Placeholders substituted"

# ── Grafana password via env override (avoids ini parsing issues) ─────────────
mkdir -p /etc/systemd/system/grafana-server.service.d
cat > /etc/systemd/system/grafana-server.service.d/override.conf << EOF
[Service]
Environment="GF_SECURITY_ADMIN_PASSWORD=$GRAFANA_PASSWORD"
Environment="GF_USERS_ALLOW_SIGN_UP=false"
EOF
echo "✅ Grafana password configured via systemd env"

# ── Permissions ───────────────────────────────────────────────────────────────
chown -R prometheus:prometheus /etc/prometheus
chown yace:yace /etc/yace/config.yml
chown -R grafana:grafana /var/lib/grafana/dashboards

# ── Start services ────────────────────────────────────────────────────────────
echo "Starting services..."
systemctl daemon-reload
systemctl enable --now yace
systemctl enable --now node_exporter
systemctl enable --now prometheus
systemctl enable --now grafana-server
sleep 10

echo "=== Service Status ==="
systemctl is-active yace           && echo "✅ yace"          || echo "❌ yace failed"
systemctl is-active node_exporter  && echo "✅ node_exporter" || echo "❌ node_exporter failed"
systemctl is-active prometheus     && echo "✅ prometheus"     || echo "❌ prometheus failed"
systemctl is-active grafana-server && echo "✅ grafana"        || echo "❌ grafana failed"

# ── Public IP via IMDSv2 ──────────────────────────────────────────────────────
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4)

echo ""
echo "════════════════════════════════════════════"
echo " Monitoring Stack Ready!"
echo " Grafana:    http://$PUBLIC_IP:3000"
echo " Prometheus: http://$PUBLIC_IP:9090"
echo "════════════════════════════════════════════"
echo "=== Setup complete at $(date) ==="
