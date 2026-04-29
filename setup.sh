#!/usr/bin/env bash
# One-command bootstrap script for deploying Langflow on a fresh Ubuntu Droplet.
# Run as root: sudo bash setup.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Colour

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# 1. Must run as root
# ---------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  error "This script must be run as root. Try: sudo bash setup.sh"
  exit 1
fi

info "Starting Langflow setup..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
generate_password() {
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
}

set_env_var() {
  local key="$1" value="$2"
  sed -i "s|^${key}=.*|${key}=${value}|" .env
}

# Read the current raw value of a key from .env (before sourcing).
get_env_var() {
  grep "^${1}=" .env | cut -d'=' -f2-
}

# Prompt the user to confirm or replace a single .env value.
#   $1  key name
#   $2  human-readable label
#   $3  non-empty = treat as a secret (hide existing value, offer auto-generate)
prompt_env_var() {
  local key="$1" label="$2" is_secret="${3:-}"
  local current
  current="$(get_env_var "${key}")"

  local prompt_text
  if [[ -n "${is_secret}" ]]; then
    if [[ -z "${current}" ]]; then
      prompt_text="${label} (leave blank to auto-generate)"
    else
      prompt_text="${label} (leave blank to keep existing)"
    fi
  else
    if [[ -n "${current}" ]]; then
      prompt_text="${label} [${current}]"
    else
      prompt_text="${label}"
    fi
  fi

  local input
  read -r -p "  ${prompt_text}: " input || true

  if [[ -n "${input}" ]]; then
    set_env_var "${key}" "${input}"
  fi
}

# ---------------------------------------------------------------------------
# 2. Configure .env
# ---------------------------------------------------------------------------
if [[ ! -f .env ]]; then
  if [[ ! -f .env.example ]]; then
    error ".env.example not found. Are you running this from the repo directory?"
    exit 1
  fi
  cp .env.example .env
  info "Created .env from .env.example."
fi

# Run interactive setup whenever the domain is still the placeholder.
if [[ "$(get_env_var DOMAIN)" == "langflow.example.com" ]]; then
  echo ""
  echo -e "${YELLOW}Please confirm or update each setting below.${NC}"
  echo -e "${YELLOW}Press Enter to accept the value shown in brackets.${NC}"
  echo ""

  prompt_env_var "DOMAIN"                      "Domain name or server IP (IP will be converted to sslip.io for HTTPS)"
  prompt_env_var "LANGFLOW_SUPERUSER"          "Langflow admin username"
  prompt_env_var "LANGFLOW_SUPERUSER_PASSWORD" "Langflow admin password"  secret
  prompt_env_var "POSTGRES_USER"               "PostgreSQL username"
  prompt_env_var "POSTGRES_PASSWORD"           "PostgreSQL password"      secret
  prompt_env_var "POSTGRES_DB"                 "PostgreSQL database name"
  prompt_env_var "LANGFLOW_VERSION"            "Langflow version tag"
  echo ""
fi

# Read needed values directly from .env using get_env_var (grep-based) instead of
# sourcing the file. This is immune to BOM bytes, encoding issues, or anything else
# on line 1, since grep matches on the KEY= prefix anywhere in the file.
DOMAIN="$(get_env_var DOMAIN)"
LANGFLOW_SUPERUSER="$(get_env_var LANGFLOW_SUPERUSER)"
LANGFLOW_SUPERUSER_PASSWORD="$(get_env_var LANGFLOW_SUPERUSER_PASSWORD)"
POSTGRES_PASSWORD="$(get_env_var POSTGRES_PASSWORD)"

# If domain is still placeholder after prompting the user, abort.
if [[ "${DOMAIN:-langflow.example.com}" == "langflow.example.com" ]]; then
  error "DOMAIN was not updated. Please enter a domain name or server IP address and re-run."
  exit 1
fi

is_ip_address() {
  [[ "${1}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Convert a bare IP to its sslip.io domain for automatic HTTPS.
if is_ip_address "${DOMAIN}"; then
  DOMAIN="${DOMAIN//./-}.sslip.io"
  set_env_var "DOMAIN" "${DOMAIN}"
  info "Using sslip.io domain for HTTPS: ${DOMAIN}"
fi

# Auto-generate any passwords left empty after prompting
GENERATED_PASSWORDS=()

if [[ -z "${LANGFLOW_SUPERUSER_PASSWORD:-}" ]]; then
  LANGFLOW_SUPERUSER_PASSWORD="$(generate_password)"
  set_env_var "LANGFLOW_SUPERUSER_PASSWORD" "${LANGFLOW_SUPERUSER_PASSWORD}"
  GENERATED_PASSWORDS+=("LANGFLOW_SUPERUSER_PASSWORD")
  info "Generated password for LANGFLOW_SUPERUSER_PASSWORD."
fi

if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
  POSTGRES_PASSWORD="$(generate_password)"
  set_env_var "POSTGRES_PASSWORD" "${POSTGRES_PASSWORD}"
  GENERATED_PASSWORDS+=("POSTGRES_PASSWORD")
  info "Generated password for POSTGRES_PASSWORD."
fi

info ".env loaded. Deploying to domain: ${DOMAIN}"

# ---------------------------------------------------------------------------
# 3. Install Docker and Docker Compose plugin
# ---------------------------------------------------------------------------
install_docker() {
  info "Installing Docker..."
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  info "Docker installed successfully."
}

if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
  info "Docker and Docker Compose plugin already installed — skipping."
else
  install_docker
fi

# ---------------------------------------------------------------------------
# 4. Configure UFW firewall
# ---------------------------------------------------------------------------
if command -v ufw &>/dev/null; then
  info "Configuring UFW firewall..."
  ufw allow 22/tcp   comment 'SSH'   > /dev/null
  ufw allow 80/tcp   comment 'HTTP'  > /dev/null
  ufw allow 443/tcp  comment 'HTTPS' > /dev/null

  if ufw status | grep -q "Status: inactive"; then
    ufw --force enable
    info "UFW enabled."
  else
    info "UFW already active — rules updated."
  fi
else
  warn "ufw not found — skipping firewall configuration."
fi

# ---------------------------------------------------------------------------
# 5. Write Caddyfile
# ---------------------------------------------------------------------------
cat > Caddyfile <<CADDY
# Reverse proxy for Langflow with automatic HTTPS via Caddy.

${DOMAIN} {
    reverse_proxy langflow:7860
}
CADDY

# ---------------------------------------------------------------------------
# 6. Pull images and start services
# ---------------------------------------------------------------------------
info "Pulling latest images..."
docker compose pull

info "Starting services..."
docker compose up -d

# ---------------------------------------------------------------------------
# 7. Wait for health checks (up to 2 minutes)
# ---------------------------------------------------------------------------
info "Waiting for services to become healthy — this may take a couple of minutes..."
TIMEOUT=120
ELAPSED=0
INTERVAL=5

all_healthy() {
  unhealthy=$(docker compose ps --format json \
    | python3 -c "
import sys, json
lines = sys.stdin.read().strip().splitlines()
count = 0
for line in lines:
    try:
        s = json.loads(line)
    except Exception:
        continue
    health = s.get('Health', '')
    if health and health != 'healthy':
        count += 1
print(count)
" 2>/dev/null || echo "1")
  [[ "${unhealthy}" == "0" ]]
}

while ! all_healthy; do
  if [[ "${ELAPSED}" -ge "${TIMEOUT}" ]]; then
    warn "Services did not all report healthy within ${TIMEOUT}s. Current status:"
    docker compose ps
    break
  fi
  printf "\r  Elapsed: %ds / %ds" "${ELAPSED}" "${TIMEOUT}"
  sleep "${INTERVAL}"
  ELAPSED=$((ELAPSED + INTERVAL))
done
printf "\r%*s\r" 40 ""  # clear the elapsed line

if all_healthy; then
  info "All services are healthy."
fi

# ---------------------------------------------------------------------------
# 8. Print summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Langflow is up and running!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  URL:        ${GREEN}https://${DOMAIN}${NC}"
echo -e "  Username:   ${LANGFLOW_SUPERUSER}"
echo -e "  Password:   ${LANGFLOW_SUPERUSER_PASSWORD}"
echo ""
if [[ "${#GENERATED_PASSWORDS[@]}" -gt 0 ]]; then
  echo -e "${YELLOW}  Auto-generated passwords have been saved to .env${NC}"
  echo -e "${YELLOW}  Keep that file safe — it contains your credentials.${NC}"
  echo ""
fi
echo -e "${YELLOW}  DNS reminder:${NC} Make sure ${DOMAIN}"
echo -e "  resolves to this server. Caddy will obtain an HTTPS"
echo -e "  certificate automatically once DNS resolves."
echo ""
echo -e "  To view logs:  docker compose logs -f"
echo -e "  To stop:       docker compose down"
echo ""
