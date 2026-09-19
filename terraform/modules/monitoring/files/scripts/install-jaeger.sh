#!/bin/bash
# Jaeger v2 (OTel Collector + storage/query/UI) — pinned version + checksum,
# systemd service. Config itself is fetched separately, before this script
# runs. See docs/design-decisions.md#self-hosted-tracing-otel-collector--jaeger-not-x-ray.
set -euo pipefail
source /etc/nexusdeploy-monitoring.env

verify_sha256() {
  echo "$2  $1" | sha256sum -c - \
    || { echo "❌ checksum mismatch for $1 — aborting"; exit 1; }
}

echo "Installing Jaeger..."
cd /tmp
JAEGER_VERSION="2.20.0"
JAEGER_SHA256="c967368ba09be356089ef7e8aab2a76d170dc007ff6ccf7925c8167ede2900d7"
wget -q -O "jaeger-${JAEGER_VERSION}-linux-amd64.tar.gz" "https://github.com/jaegertracing/jaeger/releases/download/v${JAEGER_VERSION}/jaeger-${JAEGER_VERSION}-linux-amd64.tar.gz"
verify_sha256 "jaeger-${JAEGER_VERSION}-linux-amd64.tar.gz" "$JAEGER_SHA256"
tar xf "jaeger-${JAEGER_VERSION}-linux-amd64.tar.gz"
mv "jaeger-${JAEGER_VERSION}-linux-amd64/jaeger" /usr/local/bin/
rm -rf "jaeger-${JAEGER_VERSION}-linux-amd64"*
useradd -rs /bin/false jaeger 2>/dev/null || true
mkdir -p /etc/jaeger
chown -R jaeger:jaeger /etc/jaeger

cat > /etc/systemd/system/jaeger.service << 'EOF'
[Unit]
Description=Jaeger (OTel Collector distribution)
After=network.target
[Service]
User=jaeger
ExecStart=/usr/local/bin/jaeger --config=file:/etc/jaeger/config.yaml
Restart=always
RestartSec=5
# In-memory trace storage on a 1GiB host shared with Prometheus/Grafana/
# node_exporter/YACE — cap Jaeger's own memory so a spike in trace volume
# gets Jaeger killed and restarted by systemd, not the OOM killer picking
# an arbitrary sibling service instead.
MemoryMax=256M
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now jaeger
echo "✅ Jaeger installed"
