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
STATE_BUCKET="${state_bucket}"
CONFIG_PREFIX="monitoring/config/$ENVIRONMENT"

echo "Project: $PROJECT | Environment: $ENVIRONMENT | Region: $AWS_REGION"

# ── System packages (awscli needed before SSM fetch) ─────────────────────────
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
# unknown binary. Defined here because the AWS CLI (below) is the first thing
# it guards.
verify_sha256() {
  # $1 = file path, $2 = expected hex digest
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

# ── Download binaries to /tmp ─────────────────────────────────────────────────
cd /tmp

# Every third-party binary below is pinned to an exact version AND its sha256,
# captured out-of-band from the projects' official release checksum files, and
# verified via verify_sha256 (defined near the top of this script).

# ── Install Node Exporter ─────────────────────────────────────────────────────
echo "Installing Node Exporter..."
NODEXP_VERSION="1.7.0"
NODEXP_SHA256="a550cd5c05f760b7934a2d0afad66d2e92e681482f5f57a917465b1fba3b02a6"
wget -q -O "node_exporter-$${NODEXP_VERSION}.linux-amd64.tar.gz" "https://github.com/prometheus/node_exporter/releases/download/v$${NODEXP_VERSION}/node_exporter-$${NODEXP_VERSION}.linux-amd64.tar.gz"
verify_sha256 "node_exporter-$${NODEXP_VERSION}.linux-amd64.tar.gz" "$${NODEXP_SHA256}"
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
PROM_SHA256="93460f66d17ee70df899e91db350d9705c20b1576800f96acbd78fa004e7dc07"
wget -q -O "prometheus-$${PROM_VERSION}.linux-amd64.tar.gz" "https://github.com/prometheus/prometheus/releases/download/v$${PROM_VERSION}/prometheus-$${PROM_VERSION}.linux-amd64.tar.gz"
verify_sha256 "prometheus-$${PROM_VERSION}.linux-amd64.tar.gz" "$${PROM_SHA256}"
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
  --web.listen-address=0.0.0.0:9090
# --web.enable-lifecycle intentionally omitted: it exposes /-/reload and /-/quit
# over HTTP on :9090, letting anyone who can reach the port reload or shut down
# Prometheus. Config is baked at boot from S3, so hot-reload isn't needed.
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
echo "✅ Prometheus installed"

# ── Install YACE ──────────────────────────────────────────────────────────────
echo "Installing YACE..."
YACE_VERSION="0.61.2"
YACE_SHA256="6c725906bd11eefdcfa3d7fb51063d5427d7dc34b89909295105c55780c3d335"
wget -q -O "yet-another-cloudwatch-exporter_$${YACE_VERSION}_Linux_x86_64.tar.gz" "https://github.com/nerdswords/yet-another-cloudwatch-exporter/releases/download/v$${YACE_VERSION}/yet-another-cloudwatch-exporter_$${YACE_VERSION}_Linux_x86_64.tar.gz"
verify_sha256 "yet-another-cloudwatch-exporter_$${YACE_VERSION}_Linux_x86_64.tar.gz" "$${YACE_SHA256}"
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
# 11.4.4 patches CVE-2025-4123 (open-redirect / XSS); do not drop below it.
GRAFANA_DEB_SHA256="8c38b82c3a40ebcb5e996024fe56e8584105556a8883648bad76c456f47d9647"
wget -q -O /tmp/grafana.deb "https://dl.grafana.com/oss/release/grafana_11.4.4_amd64.deb"
verify_sha256 /tmp/grafana.deb "$${GRAFANA_DEB_SHA256}"
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

# ── Grafana password via env override (avoids ini parsing issues) ─────────────
mkdir -p /etc/systemd/system/grafana-server.service.d
chmod 700 /etc/systemd/system/grafana-server.service.d
cat > /etc/systemd/system/grafana-server.service.d/override.conf << EOF
[Service]
Environment="GF_SECURITY_ADMIN_PASSWORD=$GRAFANA_PASSWORD"
Environment="GF_USERS_ALLOW_SIGN_UP=false"
EOF
chmod 600 /etc/systemd/system/grafana-server.service.d/override.conf
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

# ── Frontend console (nginx reverse proxy) ────────────────────────────────────
# Serves a lightweight static console on 443 (self-signed TLS); port 80 only
# 301-redirects to HTTPS. Reverse-proxies /api and /health to the ECS API tasks.
# The API stays private;
# only nginx on this box (already allowed to reach API:5000) talks to it, and
# access is gated by the monitoring SG's allowlist. The upstream server list is
# kept current by ecs-discovery.sh below, so it survives blue-green cutovers.
echo "Setting up frontend console (nginx)..."
apt-get install -y -qq nginx openssl

mkdir -p /var/www/frontend
aws s3 cp "s3://$STATE_BUCKET/$CONFIG_PREFIX/frontend-index.html" /var/www/frontend/index.html --region "$AWS_REGION"

# Self-signed TLS cert (demo/POC — browsers will warn; CN is cosmetic here)
mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout /etc/nginx/ssl/selfsigned.key \
  -out /etc/nginx/ssl/selfsigned.crt \
  -subj "/C=US/ST=NA/L=NA/O=$PROJECT/CN=$PROJECT-$ENVIRONMENT-console"
chmod 600 /etc/nginx/ssl/selfsigned.key

# Placeholder upstream so nginx is valid before any API task is discovered.
# ecs-discovery.sh replaces this with the live task IPs and reloads nginx.
cat > /etc/nginx/conf.d/api_upstream.conf << 'EOF'
upstream api_backend {
  server 127.0.0.1:5000; # placeholder — replaced by ecs-discovery.sh
}
EOF

rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/nexusdeploy << 'EOF'
# Port 80 exists only to redirect to HTTPS — no content is served in the clear.
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  return 301 https://$host$request_uri;
}

server {
  listen 443 ssl default_server;
  listen [::]:443 ssl default_server;
  server_name _;

  ssl_certificate     /etc/nginx/ssl/selfsigned.crt;
  ssl_certificate_key /etc/nginx/ssl/selfsigned.key;

  root /var/www/frontend;
  index index.html;

  proxy_set_header Host              $host;
  proxy_set_header X-Real-IP         $remote_addr;
  proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_connect_timeout 5s;
  proxy_read_timeout    30s;

  location / {
    try_files $uri $uri/ /index.html;
  }

  # REST API + health checks proxied to the ECS API tasks.
  location /api/     { proxy_pass http://api_backend; }
  location = /health { proxy_pass http://api_backend; }
  location = /ready  { proxy_pass http://api_backend; }
}
EOF
ln -sf /etc/nginx/sites-available/nexusdeploy /etc/nginx/sites-enabled/nexusdeploy

if nginx -t; then
  systemctl enable --now nginx
  systemctl reload nginx
  echo "✅ Frontend console configured"
else
  echo "❌ nginx config test failed"
fi

# ── ECS Service Discovery ─────────────────────────────────────────────────────
# Creates /etc/prometheus/ecs-targets.json by querying ECS for running API tasks.
# Runs every 30s via cron so targets update automatically after deployments.
cat > /usr/local/bin/ecs-discovery.sh << 'DISCOVERY'
#!/bin/bash
set -e
# One cluster per blue-green slot (dev passes a single cluster). Clusters that
# don't exist yet or have no running tasks contribute nothing — monitoring can
# come up before ECS and pick tasks up on a later cron run.
CLUSTERS="${ecs_cluster_names}"
REGION="${aws_region}"
OUTPUT="/etc/prometheus/ecs-targets.json"

TARGETS=()
for CLUSTER in $CLUSTERS; do
  # API services and task families are named "<cluster>-api"
  TASKS=$(aws ecs list-tasks   --cluster "$CLUSTER"   --family "$CLUSTER-api"   --region "$REGION"   --query 'taskArns' --output text 2>/dev/null || echo "")
  [[ -z "$TASKS" || "$TASKS" == "None" ]] && continue

  IPS=$(aws ecs describe-tasks   --cluster "$CLUSTER"   --tasks $TASKS   --region "$REGION"   --query 'tasks[*].attachments[0].details[?name==`privateIPv4Address`].value'   --output text 2>/dev/null || echo "")

  for IP in $IPS; do
    [[ -z "$IP" || "$IP" == "None" ]] && continue
    TARGETS+=("$IP:5000")
  done
done

if [[ $${#TARGETS[@]} -eq 0 ]]; then
  echo "[]" > "$OUTPUT"
else
  printf '%s\n' "$${TARGETS[@]}" | jq -R -s -c '
    split("\n") | map(select(length > 0)) |
    [{ targets: ., labels: { job: "nexusdeploy-api", environment: "${environment}" }}]
  ' > "$OUTPUT"
fi

# Keep the nginx reverse-proxy upstream in sync with the same discovered IPs so
# the frontend console reaches whichever slot is currently active. Reload only
# when the list actually changes to avoid a reload every cron tick.
NGINX_UPSTREAM="/etc/nginx/conf.d/api_upstream.conf"
if [[ -d /etc/nginx/conf.d ]]; then
  TMP=$(mktemp)
  if [[ $${#TARGETS[@]} -eq 0 ]]; then
    printf 'upstream api_backend {\n  server 127.0.0.1:5000; # no API tasks discovered\n}\n' > "$TMP"
  else
    {
      echo "upstream api_backend {"
      for T in "$${TARGETS[@]}"; do
        echo "  server $T max_fails=2 fail_timeout=10s;"
      done
      echo "}"
    } > "$TMP"
  fi
  if ! cmp -s "$TMP" "$NGINX_UPSTREAM"; then
    mv "$TMP" "$NGINX_UPSTREAM"
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
  else
    rm -f "$TMP"
  fi
fi
DISCOVERY

chmod +x /usr/local/bin/ecs-discovery.sh

# Run once immediately then every 30s via cron
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
echo "════════════════════════════════════════════"
echo "=== Setup complete at $(date) ==="
