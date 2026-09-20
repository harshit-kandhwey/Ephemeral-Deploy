#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Monitoring EC2 User Data — Ubuntu 24.04
# Bootstraps the AWS CLI (needed before any S3 fetch), then downloads and
# runs each install step from S3 — see files/scripts/. Keeping this
# orchestrator short is deliberate: user_data has a 16KB limit (gzipped).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

exec > >(tee /var/log/monitoring-setup.log) 2>&1
echo "=== Monitoring setup started at $(date) ==="

PROJECT="${project}"
ENVIRONMENT="${environment}"
AWS_REGION="${aws_region}"
STATE_BUCKET="${state_bucket}"
CONFIG_PREFIX="monitoring/config/$ENVIRONMENT"
CLUSTERS="${ecs_cluster_names}"

echo "Project: $PROJECT | Environment: $ENVIRONMENT | Region: $AWS_REGION"

# ── System packages (awscli needed before any S3 fetch) ──────────────────────
echo "Installing system packages..."
export DEBIAN_FRONTEND=noninteractive

# EC2 first boot races: cloud-init's own apt and unattended-upgrades hold the
# dpkg/apt lock. Under `set -e` a failed apt-get aborts the ENTIRE script,
# leaving every service uninstalled. Wait for boot-time apt to finish, and make
# every apt-get wait up to 5 min for the lock as a backstop.
echo 'DPkg::Lock::Timeout "300";' > /etc/apt/apt.conf.d/99lock-timeout
for i in $(seq 1 60); do
  pgrep -x apt-get >/dev/null || pgrep -x apt >/dev/null || pgrep -x dpkg >/dev/null || break
  echo "Waiting for boot-time apt/dpkg to finish... ($i)"
  sleep 5
done

apt-get update -qq
apt-get install -y -qq wget curl jq unzip

# Supply-chain guard: verify every third-party binary against a sha256 captured
# out-of-band from the project's official artifact. A tampered or truncated
# download aborts the whole setup (set -e) instead of silently running an
# unknown binary.
verify_sha256() {
  echo "$2  $1" | sha256sum -c - \
    || { echo "❌ checksum mismatch for $1 — aborting"; exit 1; }
}

# awscli not in Ubuntu 24.04 apt repos — install v2 via official installer.
# Pinned to an exact version + sha256 rather than the rolling "latest" URL so a
# compromised/republished artifact can't be installed as root.
AWSCLI_VERSION="2.24.0"
AWSCLI_SHA256="4e3c39d9881cb6f893ea93219d971390864b1f7e3756197413a7de38ce059609"
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-$${AWSCLI_VERSION}.zip" -o /tmp/awscliv2.zip
verify_sha256 /tmp/awscliv2.zip "$${AWSCLI_SHA256}"
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws
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

# ── Shared env file for the fetched install scripts ───────────────────────────
# root-only: carries the Grafana password, same posture as the old
# systemd-env-override approach it replaces. Created with mode 600 up front
# (install, not cat > then chmod after) so the secret is never briefly
# world-readable under the default umask. GRAFANA_PASSWORD goes through
# printf '%q' so install-grafana.sh's later `source` of this file can't
# re-interpret a $, backtick, quote, or backslash the password happens to
# contain — a plain unquoted heredoc interpolation writes the value
# correctly here, but sourcing re-parses it as shell syntax a second time.
install -m 600 /dev/null /etc/nexusdeploy-monitoring.env
cat > /etc/nexusdeploy-monitoring.env << EOF
PROJECT="$PROJECT"
ENVIRONMENT="$ENVIRONMENT"
AWS_REGION="$AWS_REGION"
STATE_BUCKET="$STATE_BUCKET"
CONFIG_PREFIX="$CONFIG_PREFIX"
CLUSTERS="$CLUSTERS"
GRAFANA_PASSWORD=$(printf '%q' "$GRAFANA_PASSWORD")
EOF

# ── Download configs from S3 ──────────────────────────────────────────────────
echo "Downloading configs from S3..."
mkdir -p /etc/prometheus /etc/yace /etc/jaeger \
  /etc/grafana/provisioning/datasources \
  /etc/grafana/provisioning/dashboards \
  /var/lib/grafana/dashboards

aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/prometheus.yml"              /etc/prometheus/prometheus.yml                        --region "$AWS_REGION"
aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/cloudwatch-exporter.yml"     /etc/yace/config.yml                                  --region "$AWS_REGION"
aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/jaeger-config.yaml"          /etc/jaeger/config.yaml                               --region "$AWS_REGION"
aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/grafana-datasources.yml"     /etc/grafana/provisioning/datasources/datasources.yml --region "$AWS_REGION"
aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/grafana-dashboards.yml"      /etc/grafana/provisioning/dashboards/dashboards.yml   --region "$AWS_REGION"
aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/nexusdeploy-dashboard.json"  /var/lib/grafana/dashboards/nexusdeploy.json          --region "$AWS_REGION"
echo "✅ Configs downloaded"

# ── Substitute placeholders ───────────────────────────────────────────────────
escape_sed() { printf '%s\n' "$1" | sed -e 's/[]\/$*.^[&]/\\&/g'; }
PROJECT_ESC=$(escape_sed "$PROJECT")
ENV_ESC=$(escape_sed "$ENVIRONMENT")
REGION_ESC=$(escape_sed "$AWS_REGION")
# No NEXUSDEPLOY_CLUSTER substitution: Prometheus discovers API tasks via the
# file-based ecs-targets.json (below) and YACE discovers via resource tags —
# neither config file embeds a cluster name, and blue-green has two clusters.

for f in /etc/prometheus/prometheus.yml /etc/yace/config.yml /var/lib/grafana/dashboards/nexusdeploy.json; do
  sed -i \
    -e "s/NEXUSDEPLOY_PROJECT/$PROJECT_ESC/g" \
    -e "s/NEXUSDEPLOY_ENV/$ENV_ESC/g" \
    -e "s/NEXUSDEPLOY_REGION/$REGION_ESC/g" \
    "$f"
done
echo "✅ Placeholders substituted"

# ── Fetch and run install scripts ─────────────────────────────────────────────
echo "Fetching install scripts from S3..."
mkdir -p /opt/monitoring-scripts
for script in install-node-exporter install-prometheus install-yace install-jaeger install-grafana setup-frontend ecs-discovery; do
  aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/scripts/$script.sh" "/opt/monitoring-scripts/$script.sh" --region "$AWS_REGION"
  chmod +x "/opt/monitoring-scripts/$script.sh"
done
echo "✅ Install scripts fetched"

/opt/monitoring-scripts/install-node-exporter.sh
/opt/monitoring-scripts/install-prometheus.sh
/opt/monitoring-scripts/install-yace.sh
/opt/monitoring-scripts/install-jaeger.sh
/opt/monitoring-scripts/install-grafana.sh
/opt/monitoring-scripts/setup-frontend.sh

# ── ECS Service Discovery ─────────────────────────────────────────────────────
# Kept at a fixed path for cron. Run once immediately then every 30s
# thereafter so targets update automatically after deployments.
cp /opt/monitoring-scripts/ecs-discovery.sh /usr/local/bin/ecs-discovery.sh
/usr/local/bin/ecs-discovery.sh || true
cat > /etc/cron.d/ecs-discovery << 'CRONEOF'
*/1 * * * * root /usr/local/bin/ecs-discovery.sh
*/1 * * * * root sleep 30 && /usr/local/bin/ecs-discovery.sh
CRONEOF
sleep 10

echo "=== Service Status ==="
systemctl is-active yace           && echo "✅ yace"          || echo "❌ yace failed"
systemctl is-active node_exporter  && echo "✅ node_exporter" || echo "❌ node_exporter failed"
systemctl is-active prometheus     && echo "✅ prometheus"     || echo "❌ prometheus failed"
systemctl is-active jaeger         && echo "✅ jaeger"         || echo "❌ jaeger failed"
systemctl is-active grafana-server && echo "✅ grafana"        || echo "❌ grafana failed"
systemctl is-active nginx          && echo "✅ nginx"          || echo "❌ nginx failed"

# ── Public IP via IMDSv2 ──────────────────────────────────────────────────────
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4)

echo ""
echo "════════════════════════════════════════════"
echo " Monitoring Stack Ready!"
echo " Console:    https://$PUBLIC_IP  (self-signed cert; http:// redirects here)"
echo " Grafana:    http://$PUBLIC_IP:3000"
echo " Prometheus: http://$PUBLIC_IP:9090"
echo " Jaeger UI:  loopback-only — use Grafana's Jaeger datasource or an SSM port-forward to :16686"
echo "════════════════════════════════════════════"
echo "=== Setup complete at $(date) ==="
