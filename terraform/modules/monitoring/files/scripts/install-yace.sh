#!/bin/bash
# YACE (CloudWatch Exporter) — pinned version + checksum, systemd service.
# Config itself is fetched separately, before this script runs.
set -euo pipefail
source /etc/nexusdeploy-monitoring.env

verify_sha256() {
  echo "$2  $1" | sha256sum -c - \
    || { echo "❌ checksum mismatch for $1 — aborting"; exit 1; }
}

echo "Installing YACE..."
cd /tmp
YACE_VERSION="0.61.2"
YACE_SHA256="6c725906bd11eefdcfa3d7fb51063d5427d7dc34b89909295105c55780c3d335"
wget -q -O "yet-another-cloudwatch-exporter_${YACE_VERSION}_Linux_x86_64.tar.gz" "https://github.com/nerdswords/yet-another-cloudwatch-exporter/releases/download/v${YACE_VERSION}/yet-another-cloudwatch-exporter_${YACE_VERSION}_Linux_x86_64.tar.gz"
verify_sha256 "yet-another-cloudwatch-exporter_${YACE_VERSION}_Linux_x86_64.tar.gz" "$YACE_SHA256"
tar xf "yet-another-cloudwatch-exporter_${YACE_VERSION}_Linux_x86_64.tar.gz"
# Binary may be named 'yace' or 'yet-another-cloudwatch-exporter' depending on version
mv yet-another-cloudwatch-exporter /usr/local/bin/yace 2>/dev/null || \
  mv yace /usr/local/bin/yace 2>/dev/null || \
  { echo "❌ Could not find YACE binary in tarball"; ls -la; exit 1; }
rm -f "yet-another-cloudwatch-exporter_${YACE_VERSION}_Linux_x86_64.tar.gz"
useradd -rs /bin/false yace 2>/dev/null || true
mkdir -p /etc/yace
chown yace:yace /etc/yace/config.yml

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

systemctl daemon-reload
systemctl enable --now yace
echo "✅ YACE installed"
