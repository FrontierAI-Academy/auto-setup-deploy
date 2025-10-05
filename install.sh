#!/usr/bin/env bash
set -euo pipefail

# --- Helpers ---------------------------------------------------------------
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
  red "No se encontró .env. Copia .env.example a .env y configura tus valores."
  exit 1
fi

# Cargar variables
export $(grep -v '^#' "$ENV_FILE" | xargs)

# Defaults
PORTAINER_WITH_DOMAIN="${PORTAINER_WITH_DOMAIN:-true}"

# Generar PASSWORD_32 si falta
if [ -z "${PASSWORD_32:-}" ]; then
  PASSWORD_32="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
  echo "PASSWORD_32=${PASSWORD_32}" >> "${ENV_FILE}"
  yellow "PASSWORD_32 generado automáticamente y guardado en .env"
fi

# Validaciones mínimas
for v in SERVER_IP DOMAIN EMAIL PASSWORD_32; do
  if [ -z "${!v:-}" ]; then red "Falta variable: $v en .env"; exit 1; fi
done

green "Variables cargadas:"
echo "  SERVER_IP=${SERVER_IP}"
echo "  DOMAIN=${DOMAIN}"
echo "  EMAIL=${EMAIL}"
echo "  PORTAINER_WITH_DOMAIN=${PORTAINER_WITH_DOMAIN}"

# --- Pre-requisitos --------------------------------------------------------
yellow "Actualizando paquetes e instalando Docker si falta..."
apt-get update -y
apt-get upgrade -y
apt-get install -y curl jq >/dev/null 2>&1 || true
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
fi

# --- Swarm / redes / volúmenes --------------------------------------------
yellow "Inicializando Docker Swarm (si no está)..."
if ! docker info 2>/dev/null | grep -q 'Swarm: active'; then
  docker swarm init --advertise-addr="${SERVER_IP}" || true
fi

yellow "Creando redes overlay (si no existen)..."
docker network create --driver=overlay agent_network >/dev/null 2>&1 || true
docker network create --driver=overlay traefik_public >/dev/null 2>&1 || true
docker network create --driver=overlay general_network >/dev/null 2>&1 || true

yellow "Creando volúmenes (si no existen)..."
for vol in portainer_data certificados postgres_data redis_data rabbitmq_data minio_data chatwoot_data; do
  docker volume create "$vol" >/dev/null
done

# --- Portainer inicial -----------------------------------------------------
if [ "${PORTAINER_WITH_DOMAIN}" != "true" ]; then
  yellow "Desplegando Portainer con puerto 9000 temporal..."
  docker stack deploy -c "${ROOT_DIR}/stacks/portainer.init.yaml" portainer
  green "Portainer: http://${SERVER_IP}:9000 (configura admin la primera vez)"
fi

# --- Traefik ---------------------------------------------------------------
yellow "Desplegando Traefik..."
docker stack deploy -c "${ROOT_DIR}/stacks/traefik.yaml" traefik

# --- Secret admin Portainer desde PASSWORD_32 ------------------------------
docker secret rm portainer_admin_password >/dev/null 2>&1 || true
printf '%s' "$PASSWORD_32" | docker secret create portainer_admin_password - >/dev/null

# --- Portainer con dominio -------------------------------------------------
yellow "Desplegando Portainer con dominio y Traefik..."
docker stack deploy -c "${ROOT_DIR}/stacks/portainer.yaml" portainer
green "Portainer: https://portainerapp.${DOMAIN}"

# --- Esperar Portainer listo -----------------------------------------------
yellow "Esperando a que Portainer inicialice..."
for i in $(seq 1 30); do
  if curl -sk "https://portainerapp.${DOMAIN}/api/status" >/dev/null 2>&1; then
    green "Portainer API disponible ✅"
    break
  fi
  sleep 3
done

# --- Postgres / Redis / RabbitMQ / MinIO -----------------------------------
yellow "Desplegando Postgres..."
docker stack deploy -c "${ROOT_DIR}/stacks/postgres.yaml" postgres

yellow "Desplegando Redis..."
docker stack deploy -c "${ROOT_DIR}/stacks/redis.yaml" redis

yellow "Desplegando RabbitMQ..."
docker stack deploy -c "${ROOT_DIR}/stacks/rabbitmq.yaml" rabbitmq

yellow "Desplegando MinIO..."
docker stack deploy -c "${ROOT_DIR}/stacks/minio.yaml" minio
green "MinIO Console: https://miniofrontapp.${DOMAIN}"
green "MinIO S3: https://miniobackapp.${DOMAIN}"

# --- Crear DBs necesarias en Postgres --------------------------------------
yellow "Esperando Postgres listo (max 60s)..."
for i in $(seq 1 30); do
  PGCONT=$(docker ps --filter name=postgres_postgres -q | head -n1)
  if [ -n "$PGCONT" ] && docker exec -e PGPASSWORD="${PASSWORD_32}" -i "$PGCONT" psql -U postgres -c "SELECT 1" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

yellow "Creando bases de datos chatwoot y n8n_fila (si no existen)..."
PGCONT=$(docker ps --filter name=postgres_postgres -q | head -n1)
docker exec -e PGPASSWORD="${PASSWORD_32}" -i "$PGCONT" \
  psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname='chatwoot'" | grep -q 1 || \
  docker exec -e PGPASSWORD="${PASSWORD_32}" -i "$PGCONT" psql -U postgres -c "CREATE DATABASE chatwoot"
docker exec -e PGPASSWORD="${PASSWORD_32}" -i "$PGCONT" \
  psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname='n8n_fila'" | grep -q 1 || \
  docker exec -e PGPASSWORD="${PASSWORD_32}" -i "$PGCONT" psql -U postgres -c "CREATE DATABASE n8n_fila"

# --- Chatwoot --------------------------------------------------------------
yellow "Desplegando Chatwoot..."
docker stack deploy -c "${ROOT_DIR}/stacks/chatwoot.yaml" chatwoot
yellow "Esperando chatwoot_app..."
for i in $(seq 1 60); do
  APP=$(docker ps --filter name=chatwoot_chatwoot_app -q)
  if [ -n "${APP}" ]; then break; fi
  sleep 2
done
yellow "Ejecutando migraciones Chatwoot..."
docker exec -it "$(docker ps --filter name=chatwoot_chatwoot_app -q | head -n1)" bundle exec rails db:chatwoot_prepare || true
green "Chatwoot: https://chatwootapp.${DOMAIN}"

# --- n8n -------------------------------------------------------------------
yellow "Desplegando n8n..."
docker stack deploy -c "${ROOT_DIR}/stacks/n8n.yaml" n8n
green "n8n Editor: https://n8napp.${DOMAIN}"
green "n8n Webhook: https://n8nwebhookapp.${DOMAIN}"

# --- Registrar stacks en Portainer vía API ---------------------------------
yellow "Registrando stacks en Portainer para control completo..."
PORTAINER_URL="https://portainerapp.${DOMAIN}"
PORTAINER_USER="admin"
PORTAINER_PASS="${PASSWORD_32}"

# Obtener token JWT
JWT=$(curl -sk -X POST "${PORTAINER_URL}/api/auth" \
  -H "Content-Type: application/json" \
  -d "{\"Username\": \"${PORTAINER_USER}\", \"Password\": \"${PORTAINER_PASS}\"}" | jq -r .jwt)

# Función para crear stack si no existe
deploy_stack() {
  local name="$1"
  local file="$2"
  if [ -f "${file}" ]; then
    echo "→ Registrando stack ${name}..."
    curl -sk -X POST "${PORTAINER_URL}/api/stacks/create/swarm/file" \
      -H "Authorization: Bearer ${JWT}" \
      -F "Name=${name}" \
      -F "EndpointId=1" \
      -F "SwarmID=$(docker info -f '{{.Swarm.Cluster.ID}}')" \
      -F "ComposeFile=@${file}" >/dev/null
  fi
}

deploy_stack traefik "${ROOT_DIR}/stacks/traefik.yaml"
deploy_stack portainer "${ROOT_DIR}/stacks/portainer.yaml"
deploy_stack postgres "${ROOT_DIR}/stacks/postgres.yaml"
deploy_stack redis "${ROOT_DIR}/stacks/redis.yaml"
deploy_stack rabbitmq "${ROOT_DIR}/stacks/rabbitmq.yaml"
deploy_stack minio "${ROOT_DIR}/stacks/minio.yaml"
deploy_stack chatwoot "${ROOT_DIR}/stacks/chatwoot.yaml"
deploy_stack n8n "${ROOT_DIR}/stacks/n8n.yaml"

green "✅ Todos los stacks registrados con control completo en Portainer."

# --- Resumen ---------------------------------------------------------------
green "==============================================================="
green "✅ Despliegue completo."
echo  "Configura DNS A -> ${SERVER_IP} para estos subdominios:"
cat <<DNS
- portainerapp.${DOMAIN}
- rabbitmqapp.${DOMAIN}
- miniofrontapp.${DOMAIN}
- miniobackapp.${DOMAIN}
- chatwootapp.${DOMAIN}
- n8napp.${DOMAIN}
- n8nwebhookapp.${DOMAIN}
DNS
green "Si los A records ya apuntan, Traefik emitirá certificados automáticamente."
