#!/usr/bin/env bash
set -Eeuo pipefail
APP_ROOT="${APP_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$APP_ROOT"
for entry in postgres:5432 redis:6379 kafka:9092; do
  service="${entry%:*}"
  port="${entry#*:}"
  container=$(docker compose --env-file .env -f compose/compose.yml ps -q "$service")
  ip=$(docker inspect --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$container")
  [[ -n "$ip" ]] || { echo "Missing kind network address for $service" >&2; exit 1; }
  cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: $service
  namespace: urlshortener
spec:
  ports:
    - name: tcp
      port: $port
      targetPort: $port
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: $service-external
  namespace: urlshortener
  labels:
    kubernetes.io/service-name: $service
addressType: IPv4
ports:
  - name: tcp
    protocol: TCP
    port: $port
endpoints:
  - addresses: ["$ip"]
YAML
done
