#!/bin/bash
# Frontend console (nginx reverse proxy): a static console on 443
# (self-signed TLS) that also proxies /api and /health to the ECS API
# tasks. ecs-discovery.sh keeps the upstream list current across cutovers.
set -euo pipefail
source /etc/nexusdeploy-monitoring.env

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
