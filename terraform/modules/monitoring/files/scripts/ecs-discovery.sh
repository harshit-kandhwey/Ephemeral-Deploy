#!/bin/bash
# Creates /etc/prometheus/ecs-targets.json by querying ECS for running API
# tasks, and keeps nginx's upstream in sync with the ACTIVE slot's IPs. Runs
# once at boot and every 30s via cron thereafter (installed by
# monitoring-userdata). Prometheus scrapes every slot; nginx only the active
# one, because a previous slot held at capacity through a drain would otherwise
# receive live frontend traffic on the old release.
# One cluster per blue-green slot (dev passes a single cluster). Clusters
# that don't exist yet or have no running tasks contribute nothing —
# monitoring can come up before ECS and pick tasks up on a later cron run.
set -e
source /etc/nexusdeploy-monitoring.env

REGION="$AWS_REGION"
OUTPUT="/etc/prometheus/ecs-targets.json"

# Blue-green environments pass one cluster per slot ("...-slot1"/"...-slot2");
# dev passes a single cluster with no slot and no active_slot parameter.
ACTIVE_SLOT=""
if [[ $(wc -w <<< "$CLUSTERS") -gt 1 ]]; then
  ACTIVE_SLOT=$(aws ssm get-parameter --name "/$PROJECT/$ENVIRONMENT/deployment/active_slot"     --region "$REGION" --query 'Parameter.Value' --output text 2>/dev/null || echo "")
fi

TARGETS=()        # every slot — Prometheus
NGINX_TARGETS=()  # active slot only — frontend upstream
for CLUSTER in $CLUSTERS; do
  # API services and task families are named "<cluster>-api"
  TASKS=$(aws ecs list-tasks --cluster "$CLUSTER" --family "$CLUSTER-api" --region "$REGION" --query 'taskArns' --output text 2>/dev/null || echo "")
  [[ -z "$TASKS" || "$TASKS" == "None" ]] && continue

  IPS=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks $TASKS --region "$REGION" --query 'tasks[*].attachments[0].details[?name==`privateIPv4Address`].value' --output text 2>/dev/null || echo "")

  for IP in $IPS; do
    [[ -z "$IP" || "$IP" == "None" ]] && continue
    TARGETS+=("$IP:5000")
    if [[ -z "$ACTIVE_SLOT" || "$CLUSTER" == *-"$ACTIVE_SLOT" ]]; then
      NGINX_TARGETS+=("$IP:5000")
    fi
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
# Multi-cluster but active_slot unreadable: leave the upstream as-is rather
# than guess (guessing "all slots" is the bug this avoids).
if [[ -d /etc/nginx/conf.d ]] && ! { [[ $(wc -w <<< "$CLUSTERS") -gt 1 ]] && [[ -z "$ACTIVE_SLOT" ]]; }; then
  TMP=$(mktemp)
  if [[ ${#NGINX_TARGETS[@]} -eq 0 ]]; then
    printf 'upstream api_backend {\n  server 127.0.0.1:5000; # no API tasks discovered\n}\n' > "$TMP"
  else
    {
      echo "upstream api_backend {"
      for T in "${NGINX_TARGETS[@]}"; do
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
