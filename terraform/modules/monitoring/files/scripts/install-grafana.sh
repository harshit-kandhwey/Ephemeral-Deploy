#!/bin/bash
# Grafana — pinned .deb + checksum via apt. Datasources/dashboards configs
# are fetched separately, before this script runs.
set -euo pipefail
source /etc/nexusdeploy-monitoring.env

verify_sha256() {
  echo "$2  $1" | sha256sum -c - \
    || { echo "❌ checksum mismatch for $1 — aborting"; exit 1; }
}

echo "Installing Grafana..."
# 11.4.4 patches CVE-2025-4123 (open-redirect / XSS); do not drop below it.
GRAFANA_DEB_SHA256="8c38b82c3a40ebcb5e996024fe56e8584105556a8883648bad76c456f47d9647"
wget -q -O /tmp/grafana.deb "https://dl.grafana.com/oss/release/grafana_11.4.4_amd64.deb"
verify_sha256 /tmp/grafana.deb "$GRAFANA_DEB_SHA256"
apt-get install -y -qq /tmp/grafana.deb
rm -f /tmp/grafana.deb

chown -R grafana:grafana /var/lib/grafana/dashboards

# Password via systemd env override, not grafana.ini — avoids ini parsing
# issues and keeps the secret out of a file grafana itself might log.
mkdir -p /etc/systemd/system/grafana-server.service.d
chmod 700 /etc/systemd/system/grafana-server.service.d
cat > /etc/systemd/system/grafana-server.service.d/override.conf << EOF
[Service]
Environment="GF_SECURITY_ADMIN_PASSWORD=$GRAFANA_PASSWORD"
Environment="GF_USERS_ALLOW_SIGN_UP=false"
EOF
chmod 600 /etc/systemd/system/grafana-server.service.d/override.conf

systemctl daemon-reload
systemctl enable --now grafana-server
echo "✅ Grafana installed"
