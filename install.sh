#!/usr/bin/env bash
set -euo pipefail

# === Helpers ===
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
  red "No se encontró .env. Copia .env.example a .env y configura tus valores."
  exit 1
fi

# === Variables ===
export $(grep -v '^#' "$ENV_FILE" | xargs)
PORTAINER_WITH_DOMAIN="${PORTAINER_WITH_DOMAIN:-true}"

if [ -z "${PASSWORD_32:-}" ]; then
  PASSWORD_32="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
  echo "PASSWORD_32=${PASSWORD_32}" >> "${ENV_FILE}"
  yellow "PASSWORD_32 generado automáticamente y guardado en .env"
fi

green "Variables cargadas:"
echo "  SERVER_IP=${SERVER_IP}"
echo "  DOMAIN=${DOMAIN}"
echo "  EMAIL=${EMAIL}"

# === Instalar dependencias básicas ===
apt-get update -y
apt-get install -y curl jq gettext >/dev/null 2>&1 || true

# === Instalar Docker si falta ===
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

# === Inicializar Swarm ===
if ! docker info 2>/dev/null | grep -q 'Swarm: active'; then
  yellow "Inicializando Docker Swarm..."
  docker swarm init --advertise-addr="${SERVER_IP}" || true
fi

# === Redes y volúmenes ===
yellow "Creando redes overlay..."
for net in agent_network traefik_public general_network; do
  docker network create --driver=overlay "$net" >/dev/null 2>&1 || true
done

yellow "Creando volúmenes..."
for vol in portainer_data certificados postgres_data redis_data rabbitmq_data minio_data chatwoot_data; do
  docker volume create "$vol" >/dev/null 2>&1 || true
done

# === Traefik ===
yellow "Desplegando Traefik..."
envsubst < "${ROOT_DIR}/stacks/traefik.yaml" | docker stack deploy -c - traefik

# === Portainer ===
yellow "Creando secret de admin Portainer..."
docker secret rm portainer_admin_password >/dev/null 2>&1 || true
printf '%s' "$PASSWORD_32" | docker secret create portainer_admin_password - >/dev/null

yellow "Desplegando Portainer..."
envsubst < "${ROOT_DIR}/stacks/portainer.yaml" | docker stack deploy -c - portainer

# === Esperar Portainer ===
yellow "Esperando Portainer (máx 60s)..."
for i in $(seq 1 60); do
  if curl -sk "https://portainerapp.${DOMAIN}/api/status" >/dev/null 2>&1; then
    green "✅ Portainer disponible"
    break
  fi
  sleep 3
done

# === Servicios base ===
for svc in postgres redis rabbitmq minio; do
  yellow "Desplegando $svc..."
  envsubst < "${ROOT_DIR}/stacks/${svc}.yaml" | docker stack deploy -c - "$svc"
done

green "MinIO Console: https://miniofrontapp.${DOMAIN}"
green "MinIO S3:      https://miniobackapp.${DOMAIN}"

# === Bases de datos ===
yellow "Esperando Postgres..."
for i in $(seq 1 30); do
  PG=$(docker ps --filter name=postgres_postgres -q | head -n1)
  if [ -n "$PG" ] && docker exec -e PGPASSWORD="${PASSWORD_32}" -i "$PG" psql -U postgres -c "SELECT 1" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

yellow "Creando bases chatwoot y n8n_fila..."
PG=$(docker ps --filter name=postgres_postgres -q | head -n1)
for DB in chatwoot n8n_fila; do
  docker exec -e PGPASSWORD="${PASSWORD_32}" -i "$PG" \
    psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname='${DB}'" | grep -q 1 || \
    docker exec -e PGPASSWORD="${PASSWORD_32}" -i "$PG" psql -U postgres -c "CREATE DATABASE ${DB}"
done

# === Chatwoot ===
yellow "Desplegando Chatwoot..."
envsubst < "${ROOT_DIR}/stacks/chatwoot.yaml" | docker stack deploy -c - chatwoot
for i in $(seq 1 60); do
  APP=$(docker ps --filter name=chatwoot_chatwoot_app -q)
  [ -n "${APP}" ] && break
  sleep 2
done
docker exec -it "$(docker ps --filter name=chatwoot_chatwoot_app -q | head -n1)" bundle exec rails db:chatwoot_prepare || true
green "Chatwoot: https://chatwootapp.${DOMAIN}"

# === n8n ===
yellow "Desplegando n8n..."
envsubst < "${ROOT_DIR}/stacks/n8n.yaml" | docker stack deploy -c - n8n
green "n8n Editor:  https://n8napp.${DOMAIN}"
green "n8n Webhook: https://n8nwebhookapp.${DOMAIN}"

# === Reconstrucción Full control en Portainer ===
yellow "Reconstruyendo stacks bajo control FULL en Portainer..."

PORTAINER_URL="https://portainerapp.${DOMAIN}"
PORTAINER_USER="admin"
PORTAINER_PASS="${PASSWORD_32}"
STACKS_DIR="${ROOT_DIR}/stacks"
JWT=$(curl -sk -X POST "${PORTAINER_URL}/api/auth" \
  -H "Content-Type: application/json" \
  -d "{\"Username\": \"${PORTAINER_USER}\", \"Password\": \"${PORTAINER_PASS}\"}" | jq -r .jwt)

if [ "$JWT" != "null" ] && [ -n "$JWT" ]; then
  ENDPOINT_ID=1
  SWARM_ID=$(docker info -f '{{.Swarm.Cluster.ID}}')

  echo "🧹 Eliminando stacks anteriores..."
  for s in chatwoot minio n8n portainer postgres rabbitmq redis traefik; do
    docker stack rm "$s" >/dev/null 2>&1 || true
  done

  echo "⏳ Esperando que no queden servicios..."
  for i in $(seq 1 60); do
    ACTIVE=$(docker service ls -q | wc -l)
    [ "$ACTIVE" -eq 0 ] && break
    sleep 3
  done

  echo "➡️  Recreando stacks finales..."
  for f in ${STACKS_DIR}/*.yaml; do
    NAME=$(basename "$f" .yaml)
    TMP_FILE="/tmp/${NAME}.yaml"
    envsubst < "$f" > "$TMP_FILE"
    curl -sk -X POST "${PORTAINER_URL}/api/stacks/create/swarm/file" \
      -H "Authorization: Bearer ${JWT}" \
      -F "Name=${NAME}" \
      -F "SwarmID=${SWARM_ID}" \
      -F "EndpointId=${ENDPOINT_ID}" \
      -F "ComposeFile=@${TMP_FILE}" >/dev/null
  done

  green "✅ Stacks recreados con control total en Portainer."
else
  red "❌ Error autenticando con la API de Portainer."
fi

# === Auto-levantamiento final ===
yellow "➡️  Re-desplegando stacks finales..."
for f in ${STACKS_DIR}/*.yaml; do
  NAME=$(basename "$f" .yaml)
  envsubst < "$f" | docker stack deploy -c - "$NAME"
done
green "✅ Todos los stacks fueron levantados nuevamente y están corriendo."
docker service ls

# === Resumen ===
green "==============================================================="
green "✅ Despliegue completo listo."
echo "Configura DNS A -> ${SERVER_IP} para:"
cat <<DNS
- portainerapp.${DOMAIN}
- rabbitmqapp.${DOMAIN}
- miniofrontapp.${DOMAIN}
- miniobackapp.${DOMAIN}
- chatwootapp.${DOMAIN}
- n8napp.${DOMAIN}
- n8nwebhookapp.${DOMAIN}
DNS
green "Traefik emitirá certificados automáticamente al detectar los dominios."
