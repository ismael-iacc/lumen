#!/bin/bash
# =============================================================================
# lumen-setup.sh — One-command installer for the Lumen Security Scanning Platform
#
# Downloads the docker-compose template from GitHub, generates secure random
# credentials, spins up all services, and prints the generated config.
#
# Install:
#   curl -sSL https://raw.githubusercontent.com/ismael-iacc/lumen/main/lumen-setup.sh | bash
#
# Options:
#   --dir PATH       Installation directory (default: ./lumen)
#   --port PORT      API port (default: 8000)
#   --clean          Remove existing installation first
#   --no-start       Only generate files, don't start services
# =============================================================================
set -euo pipefail

GITHUB_RAW="https://raw.githubusercontent.com/ismael-iacc/lumen/refs/heads/main"
INSTALL_DIR="./lumen"
API_PORT=8000
CLEAN=false
NO_START=false

# ── Parse args ──
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)       INSTALL_DIR="$2"; shift 2 ;;
    --port)      API_PORT="$2"; shift 2 ;;
    --clean)     CLEAN=true; shift ;;
    --no-start)  NO_START=true; shift ;;
    --help|-h)
      sed -n '2,/^# =====/p' "$0" 2>/dev/null | head -n -1 | sed 's/^# \?//' || true
      echo ""
      echo "Usage: curl -sSL $GITHUB_RAW/lumen-setup.sh | bash"
      exit 0
      ;;
    *) echo "[ERROR] Unknown option: $1"; exit 1 ;;
  esac
done

# ── Helpers ──
rand_string() {
  # Generate a random alphanumeric string of given length
  local len="${1:-32}"
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$len" || \
  python3 -c "import secrets; print(secrets.token_urlsafe($len)[:$len])" 2>/dev/null || \
  openssl rand -base64 "$len" 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$len"
}

rand_password() {
  # Generate a password with mixed chars
  local len="${1:-24}"
  LC_ALL=C tr -dc 'A-Za-z0-9!@#%&_+=' </dev/urandom 2>/dev/null | head -c "$len" || \
  python3 -c "import secrets; print(secrets.token_urlsafe($len)[:$len])" 2>/dev/null
}

# ── Banner ──
echo ""
echo "  ╦  ╦ ╦╔╦╗╔═╗╔╗╔"
echo "  ║  ║ ║║║║║╣ ║║║"
echo "  ╩═╝╚═╝╩ ╩╚═╝╝╚╝"
echo "  Security Scanning Platform"
echo ""

# ── Prerequisites ──
echo "[*] Checking prerequisites..."

if ! command -v docker &>/dev/null; then
  echo "[ERROR] Docker is not installed. Install it from https://docs.docker.com/get-docker/"
  exit 1
fi

if ! docker info &>/dev/null 2>&1; then
  echo "[ERROR] Docker daemon is not running."
  exit 1
fi

if ! docker compose version &>/dev/null 2>&1; then
  echo "[ERROR] Docker Compose plugin is required. Install: https://docs.docker.com/compose/install/"
  exit 1
fi

echo "[OK] Docker and Docker Compose detected."
echo ""

# ── Clean ──
if [[ "$CLEAN" == true && -d "$INSTALL_DIR" ]]; then
  echo "[*] Cleaning existing installation at ${INSTALL_DIR}..."
  docker compose -f "$INSTALL_DIR/docker-compose.yaml" down -v --remove-orphans 2>/dev/null || true
  rm -rf "$INSTALL_DIR"
  echo "[OK] Cleaned."
  echo ""
fi

# ── Create install dir ──
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ── Download template ──
echo "[*] Downloading docker-compose template..."
curl -sSL "${GITHUB_RAW}/docker-compose.template.yml" -o docker-compose.yaml || {
  echo "[ERROR] Failed to download template from GitHub."
  echo "        URL: ${GITHUB_RAW}/docker-compose.template.yml"
  exit 1
}
echo "[OK] Template downloaded."

# ── Generate credentials ──
echo "[*] Generating secure credentials..."

LUMEN_DB_USER="lumen_db"
LUMEN_DB_NAME="lumen"
LUMEN_DB_PASSWORD="$(rand_password 24)"
LUMEN_MQ_USER="lumen_mq"
LUMEN_MQ_PASSWORD="$(rand_password 24)"
LUMEN_API_USER="lumen-ci"
LUMEN_API_PASSWORD="$(rand_password 28)"
LUMEN_JWT_SECRET="$(rand_string 64)"
LUMEN_EXCHANGE="lumen-svc"
LUMEN_API_PORT="$API_PORT"
LUMEN_MQ_PORT="5672"
LUMEN_MQ_MGMT_PORT="15672"

# ── Write .env ──
cat > .env <<ENVEOF
# ============================================
# Lumen — Generated credentials
# Created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# ============================================

# PostgreSQL
LUMEN_DB_USER=${LUMEN_DB_USER}
LUMEN_DB_PASSWORD=${LUMEN_DB_PASSWORD}
LUMEN_DB_NAME=${LUMEN_DB_NAME}

# RabbitMQ
LUMEN_MQ_USER=${LUMEN_MQ_USER}
LUMEN_MQ_PASSWORD=${LUMEN_MQ_PASSWORD}
LUMEN_MQ_PORT=${LUMEN_MQ_PORT}
LUMEN_MQ_MGMT_PORT=${LUMEN_MQ_MGMT_PORT}

# API Gateway
LUMEN_API_USER=${LUMEN_API_USER}
LUMEN_API_PASSWORD=${LUMEN_API_PASSWORD}
LUMEN_API_PORT=${LUMEN_API_PORT}

# Security
LUMEN_JWT_SECRET=${LUMEN_JWT_SECRET}

# Messaging
LUMEN_EXCHANGE=${LUMEN_EXCHANGE}
ENVEOF

echo "[OK] Credentials generated and saved to .env"
echo ""

# ── Show what was generated ──
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                  GENERATED CONFIGURATION                         ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║"
echo "║  PostgreSQL"
echo "║    User:      ${LUMEN_DB_USER}"
echo "║    Password:  ${LUMEN_DB_PASSWORD}"
echo "║    Database:  ${LUMEN_DB_NAME}"
echo "║"
echo "║  RabbitMQ"
echo "║    User:      ${LUMEN_MQ_USER}"
echo "║    Password:  ${LUMEN_MQ_PASSWORD}"
echo "║    AMQP Port: ${LUMEN_MQ_PORT}"
echo "║    Mgmt Port: ${LUMEN_MQ_MGMT_PORT}"
echo "║"
echo "║  API Gateway"
echo "║    User:      ${LUMEN_API_USER}"
echo "║    Password:  ${LUMEN_API_PASSWORD}"
echo "║    Port:      ${LUMEN_API_PORT}"
echo "║"
echo "║  JWT Secret:  ${LUMEN_JWT_SECRET:0:16}..."
echo "║  Exchange:    ${LUMEN_EXCHANGE}"
echo "║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

if [[ "$NO_START" == true ]]; then
  echo "[OK] Files generated at: $(pwd)"
  echo "     To start: cd $(pwd) && docker compose up -d"
  exit 0
fi

# ── Start services ──
echo "[*] Pulling images and starting services..."
docker compose up -d --pull always || {
  echo ""
  echo "[WARN] Pull from registry failed — attempting local build..."
  docker compose up -d --build
}

echo ""
echo "[*] Waiting for services to become healthy..."

MAX_WAIT=180
ELAPSED=0
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  if curl -sf "http://localhost:${LUMEN_API_PORT}/api/v1/health" > /dev/null 2>&1; then
    break
  fi
  sleep 3
  ELAPSED=$((ELAPSED + 3))
  printf "\r    Waiting for API... %ds / %ds" "$ELAPSED" "$MAX_WAIT"
done
echo ""

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  echo "[WARN] API did not respond within ${MAX_WAIT}s."
  echo "       Check logs: docker compose -f $(pwd)/docker-compose.yaml logs"
  echo "       It may still be starting (CodeQL agent image is large)."
  echo ""
else
  echo "[OK] API Gateway is healthy!"
fi

# ── Summary ──
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                    LUMEN IS RUNNING                            ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║"
echo "║  API:         http://localhost:${LUMEN_API_PORT}/api/v1"
echo "║  API Docs:    http://localhost:${LUMEN_API_PORT}/docs"
echo "║  RabbitMQ UI: http://localhost:${LUMEN_MQ_MGMT_PORT}"
echo "║"
echo "║  To scan a repo:"
echo "║    export SCAN_API_URL=http://localhost:${LUMEN_API_PORT}/api/v1"
echo "║    export SCAN_API_USERNAME=${LUMEN_API_USER}"
echo "║    export SCAN_API_PASSWORD=${LUMEN_API_PASSWORD}"
echo "║"
echo "║    curl -sSL ${GITHUB_RAW}/lumen.sh | bash -s -- \\"
echo "║      --repo https://github.com/user/repo \\"
echo "║      --language python --wait --output report.sarif"
echo "║"
echo "║  Logs:   docker compose -f $(pwd)/docker-compose.yaml logs -f"
echo "║  Stop:   docker compose -f $(pwd)/docker-compose.yaml down"
echo "║  Reset:  re-run with --clean"
echo "║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
