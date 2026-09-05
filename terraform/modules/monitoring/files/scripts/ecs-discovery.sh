#!/bin/bash
# Creates /etc/prometheus/ecs-targets.json by querying ECS for running API
# tasks, and keeps nginx's upstream in sync with the same IPs. Runs once at
# boot and every 30s via cron thereafter (installed by monitoring-userdata).
# One cluster per blue-green slot (dev passes a single cluster). Clusters
# that don't exist yet or have no running tasks contribute nothing —
# monitoring can come up before ECS and pick tasks up on a later cron run.
set -e
source /etc/nexusdeploy-monitoring.env

REGION="$AWS_REGION"
OUTPUT="/etc/prometheus/ecs-targets.json"

TARGETS=()
for CLUSTER in $CLUSTERS; do
  # API services and task families are named "<cluster>-api"
  TASKS=$(aws ecs list-tasks --cluster "$CLUSTER" --family "$CLUSTER-api" --region "$REGION" --query 'taskArns' --output text 2>/dev/null || echo "")
  [[ -z "$TASKS" || "$TASKS" == "None" ]] && continue

  IPS=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks $TASKS --region "$REGION" --query 'tasks[*].attachments[0].details[?name==`privateIPv4Address`].value' --output text 2>/dev/null || echo "")

  for IP in $IPS; do
    [[ -z "$IP" || "$IP" == "None" ]] && continue
    TARGETS+=("$IP:5000")
  done
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "[]" > "$OUTPUT"
else
  printf '%s\n' "${TARGETS[@]}" | jq -R -s -c --arg env "$ENVIRONMENT" '
    split("\n") | map(select(length > 0)) |
    [{ targets: ., labels: { job: "nexusdeploy-api", environment: $env }}]
  ' > "$OUTPUT"
fi

# Keep the nginx reverse-proxy upstream in sync with the same discovered IPs so
# the frontend console reaches whichever slot is currently active. Reload only
# when the list actually changes to avoid a reload every cron tick.
NGINX_UPSTREAM="/etc/nginx/conf.d/api_upstream.conf"
if [[ -d /etc/nginx/conf.d ]]; then
  TMP=$(mktemp)
  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    printf 'upstream api_backend {\n  server 127.0.0.1:5000; # no API tasks discovered\n}\n' > "$TMP"
  else
    {
      echo "upstream api_backend {"
      for T in "${TARGETS[@]}"; do
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
