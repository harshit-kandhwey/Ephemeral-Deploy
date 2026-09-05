#!/bin/bash
# Node Exporter — pinned version + checksum, systemd service.
# Fetched from S3 and run by monitoring-userdata.sh.tpl; not templated by
# Terraform (plain bash, no ${...} interpolation risk).
set -euo pipefail
source /etc/nexusdeploy-monitoring.env

verify_sha256() {
  echo "$2  $1" | sha256sum -c - \
    || { echo "❌ checksum mismatch for $1 — aborting"; exit 1; }
}

echo "Installing Node Exporter..."
cd /tmp
NODEXP_VERSION="1.7.0"
NODEXP_SHA256="a550cd5c05f760b7934a2d0afad66d2e92e681482f5f57a917465b1fba3b02a6"
wget -q -O "node_exporter-${NODEXP_VERSION}.linux-amd64.tar.gz" "https://github.com/prometheus/node_exporter/releases/download/v${NODEXP_VERSION}/node_exporter-${NODEXP_VERSION}.linux-amd64.tar.gz"
verify_sha256 "node_exporter-${NODEXP_VERSION}.linux-amd64.tar.gz" "$NODEXP_SHA256"
tar xf "node_exporter-${NODEXP_VERSION}.linux-amd64.tar.gz"
mv "node_exporter-${NODEXP_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
rm -rf "node_exporter-${NODEXP_VERSION}"*
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

systemctl daemon-reload
systemctl enable --now node_exporter
echo "✅ Node Exporter installed"
