#!/bin/bash
# Prometheus — pinned version + checksum, systemd service. Config itself
# (prometheus.yml) is fetched separately, before this script runs.
set -euo pipefail
source /etc/nexusdeploy-monitoring.env

verify_sha256() {
  echo "$2  $1" | sha256sum -c - \
    || { echo "❌ checksum mismatch for $1 — aborting"; exit 1; }
}

echo "Installing Prometheus..."
cd /tmp
PROM_VERSION="2.49.1"
PROM_SHA256="93460f66d17ee70df899e91db350d9705c20b1576800f96acbd78fa004e7dc07"
wget -q -O "prometheus-${PROM_VERSION}.linux-amd64.tar.gz" "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz"
verify_sha256 "prometheus-${PROM_VERSION}.linux-amd64.tar.gz" "$PROM_SHA256"
tar xf "prometheus-${PROM_VERSION}.linux-amd64.tar.gz"
mv "prometheus-${PROM_VERSION}.linux-amd64/prometheus" /usr/local/bin/
mv "prometheus-${PROM_VERSION}.linux-amd64/promtool"   /usr/local/bin/
rm -rf "prometheus-${PROM_VERSION}"*
mkdir -p /etc/prometheus /var/lib/prometheus
useradd -rs /bin/false prometheus 2>/dev/null || true
# -R: prometheus.yml was already downloaded into /etc/prometheus by user-data,
# owned by root — this picks it up along with the directory itself.
chown -R prometheus:prometheus /var/lib/prometheus /etc/prometheus

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

systemctl daemon-reload
systemctl enable --now prometheus
echo "✅ Prometheus installed"
