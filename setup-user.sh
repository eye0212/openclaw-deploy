#!/usr/bin/env bash
# setup-user.sh — VPS user-level setup for OpenClaw
# Run as the 'openclaw' user on the VPS
# Usage: bash ~/openclaw-deploy/setup-user.sh

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
banner()  { echo -e "\n${BOLD}━━━ $* ━━━${NC}\n"; }

# ── Concurrency lock ──────────────────────────────────────────────────────────
exec 9>/tmp/openclaw-setup-user.lock
if ! flock -n 9; then
  error "Setup is already running (lock file: /tmp/openclaw-setup-user.lock)."
  exit 1
fi

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_FILE="${HOME}/openclaw-setup.log"
exec 1> >(tee -a "${LOG_FILE}"); exec 2>&1
banner "OpenClaw User Setup — $(date)"
info "Logging to ${LOG_FILE}"

# ── Temp file cleanup ─────────────────────────────────────────────────────────
TMPFILES=()
cleanup() {
  if (( ${#TMPFILES[@]} > 0 )); then
    rm -rf "${TMPFILES[@]}"
  fi
}
trap cleanup EXIT INT TERM

# ── Helper functions ──────────────────────────────────────────────────────────

# Fetch the latest release version from GitHub API.
# Usage: get_github_release "owner/repo"
# Outputs version string (without 'v' prefix); returns 1 on failure.
get_github_release() {
  local repo="$1"
  local version
  version=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
  if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "Could not determine ${repo} version (got: '${version}'). Check GitHub API rate limit or try again."
    return 1
  fi
  echo "${version}"
}

# Pre-flight check that all Docker image tags exist in the registry.
# Reads tags from ${COMPOSE_DIR}/.env and runs docker manifest inspect for each.
# Exits 1 if any tag is not found, before docker compose up wastes bandwidth.
verify_image_tags() {
  local n8n_tag uptime_tag whisper_tag ollama_tag
  n8n_tag=$(grep "^N8N_IMAGE_TAG="         "${COMPOSE_DIR}/.env" | cut -d= -f2 || echo "latest")
  uptime_tag=$(grep "^UPTIME_KUMA_IMAGE_TAG=" "${COMPOSE_DIR}/.env" | cut -d= -f2 || echo "latest")
  whisper_tag=$(grep "^WHISPER_IMAGE_TAG="   "${COMPOSE_DIR}/.env" | cut -d= -f2 || echo "latest")
  ollama_tag=$(grep "^OLLAMA_IMAGE_TAG="     "${COMPOSE_DIR}/.env" | cut -d= -f2 || echo "0.6.2")

  local images=(
    "n8nio/n8n:${n8n_tag}"
    "louislam/uptime-kuma:${uptime_tag}"
    "onerahmet/openai-whisper-asr-webservice:${whisper_tag}"
    "ollama/ollama:${ollama_tag}"
  )

  local failed=0
  for img in "${images[@]}"; do
    info "Verifying image tag: ${img}"
    if ! docker manifest inspect "${img}" &>/dev/null; then
      error "Docker image not found or unreachable: ${img}"
      error "  Fix the tag in ~/compose/.env, then re-run setup-user.sh"
      error "  Browse available tags at: https://hub.docker.com"
      failed=1
    fi
  done

  if [[ ${failed} -eq 1 ]]; then
    error "One or more image tags are invalid — aborting before docker compose up."
    exit 1
  fi
  success "All Docker image tags verified"
}

# Verify SHA-256 checksum of a file.
# Usage: verify_sha256 <file> <expected_hash>
# Returns 1 on mismatch.
verify_sha256() {
  local file="$1"
  local expected_hash="$2"
  local actual_hash
  actual_hash=$(sha256sum "${file}" | awk '{print $1}')
  if [[ -z "${expected_hash}" || "${expected_hash}" != "${actual_hash}" ]]; then
    error "Checksum mismatch for $(basename "${file}")!"
    error "  Expected: ${expected_hash:-<empty>}"
    error "  Got:      ${actual_hash}"
    return 1
  fi
}

# ── Preflight ────────────────────────────────────────────────────────────────
if [[ "$(whoami)" != "openclaw" ]]; then
  error "This script must be run as the 'openclaw' user."
  error "Run: su - openclaw"
  exit 1
fi

if [[ ! -f ~/openclaw-deploy/.env ]]; then
  error ".env not found at ~/openclaw-deploy/.env"
  error "Make sure setup-root.sh completed successfully."
  exit 1
fi

DEPLOY_DIR="${HOME}/openclaw-deploy"
COMPOSE_DIR="${HOME}/compose"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
banner "Pre-flight checks"

if ! curl -sf https://api.github.com --head -o /dev/null 2>/dev/null; then
  error "Cannot reach api.github.com — check network connectivity."
  exit 1
fi
success "GitHub API reachable"

# Verify setup-root.sh installed the required tools
for _tool in dockerd-rootless-setuptool.sh age age-keygen sops; do
  if ! command -v "${_tool}" &>/dev/null; then
    error "Required tool not found: ${_tool}"
    error "Did setup-root.sh complete successfully? Run it first:"
    error "  bash /root/openclaw-deploy/setup-root.sh"
    exit 1
  fi
done
unset _tool
success "Required tools present (docker-rootless, age, sops)"

# ── Step 1: Rootless Docker ──────────────────────────────────────────────────
banner "Step 1/6: Rootless Docker"

# Docker rootless prerequisites are installed by setup-root.sh
# If this check fires, it means setup-root.sh was skipped — pre-flight above already caught it

# Enable lingering for systemd user session
sudo loginctl enable-linger openclaw 2>/dev/null || true
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

# Run rootless setup
if ! systemctl --user is-active docker &>/dev/null 2>&1; then
  info "Setting up rootless Docker..."
  dockerd-rootless-setuptool.sh install
  success "Rootless Docker installed"
else
  info "Rootless Docker already running, skipping"
fi

# Add to .bashrc
BASHRC="${HOME}/.bashrc"
DOCKER_HOST_LINE='export DOCKER_HOST=unix://${XDG_RUNTIME_DIR}/docker.sock'
PATH_DOCKER_LINE='export PATH="${HOME}/bin:${PATH}"'

if ! grep -q "docker.sock" "${BASHRC}" 2>/dev/null; then
  {
    echo ""
    echo "# Rootless Docker"
    echo "${DOCKER_HOST_LINE}"
    echo "${PATH_DOCKER_LINE}"
    echo 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"'
  } >> "${BASHRC}"
  success "Added Docker env to ~/.bashrc"
fi

# Export for this session
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
export PATH="${HOME}/bin:${PATH}"
success "Rootless Docker configured"

# Verify Docker is functional
if ! docker info &>/dev/null; then
  error "Docker daemon is not accessible after setup. Check rootless Docker installation."
  exit 1
fi
success "Docker daemon verified"

# ── Step 2: Docker Compose plugin ────────────────────────────────────────────
banner "Step 2/6: Docker Compose plugin"
COMPOSE_PLUGIN_DIR="${HOME}/.docker/cli-plugins"
mkdir -p "${COMPOSE_PLUGIN_DIR}"

if docker compose version &>/dev/null; then
  success "Docker Compose already available: $(docker compose version --short 2>/dev/null || docker compose version)"
elif [[ ! -f "${COMPOSE_PLUGIN_DIR}/docker-compose" ]]; then
  info "Downloading Docker Compose plugin..."
  ARCH=$(dpkg --print-architecture)
  COMPOSE_VERSION=$(get_github_release "docker/compose") || exit 1
  COMPOSE_URL="https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${ARCH}"
  COMPOSE_SHA_URL="${COMPOSE_URL}.sha256"
  COMPOSE_TMP=$(mktemp); TMPFILES+=("${COMPOSE_TMP}")
  curl -fsSL "${COMPOSE_URL}" -o "${COMPOSE_TMP}"
  # .sha256 not present in all releases — verify if available, skip with warning otherwise
  COMPOSE_SHA_TMP=$(mktemp); TMPFILES+=("${COMPOSE_SHA_TMP}")
  if curl -fsSL "${COMPOSE_SHA_URL}" -o "${COMPOSE_SHA_TMP}" 2>/dev/null; then
    EXPECTED_HASH=$(awk '{print $1}' "${COMPOSE_SHA_TMP}")
    verify_sha256 "${COMPOSE_TMP}" "${EXPECTED_HASH}" || {
      error "Docker Compose download aborted due to checksum mismatch."
      exit 1
    }
    success "Docker Compose v${COMPOSE_VERSION} checksum verified"
  else
    warn "Docker Compose sha256 not available for v${COMPOSE_VERSION} — skipping checksum verification"
  fi
  install -m 755 "${COMPOSE_TMP}" "${COMPOSE_PLUGIN_DIR}/docker-compose"
  success "Docker Compose v${COMPOSE_VERSION} installed"
else
  info "Docker Compose plugin already installed"
fi

# Docker daemon config (log limits)
mkdir -p "${HOME}/.config/docker"
cat > "${HOME}/.config/docker/daemon.json" << 'DOCKERDAEMON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
DOCKERDAEMON
success "Docker daemon config written"

# Restart docker to apply daemon config
systemctl --user restart docker 2>/dev/null || true
sleep 2

# ── Step 3: Generate age key and encrypt .env ─────────────────────────────────
banner "Step 3/6: Generate encryption key + encrypt .env"

mkdir -p "${HOME}/.config/age"
AGE_KEY_FILE="${HOME}/.config/age/keys.txt"

if [[ ! -f "${AGE_KEY_FILE}" ]]; then
  age-keygen -o "${AGE_KEY_FILE}"
  chmod 600 "${AGE_KEY_FILE}"
  success "age key generated at ${AGE_KEY_FILE}"
else
  info "age key already exists, reusing"
fi

AGE_PUBLIC_KEY=$(age-keygen -y "${AGE_KEY_FILE}")
info "age public key: ${AGE_PUBLIC_KEY}"

# Encrypt .env
ENV_FILE="${DEPLOY_DIR}/.env"
ENV_ENC="${DEPLOY_DIR}/.env.enc"

if [[ ! -f "${ENV_ENC}" || "${ENV_FILE}" -nt "${ENV_ENC}" ]]; then
  # Re-encrypt if .env.enc doesn't exist or .env is newer (e.g., TAILSCALE_IP was patched)
  SOPS_AGE_KEY_FILE="${AGE_KEY_FILE}" sops --age="${AGE_PUBLIC_KEY}" -e "${ENV_FILE}" > "${ENV_ENC}.tmp"
  mv "${ENV_ENC}.tmp" "${ENV_ENC}"
  success ".env encrypted to .env.enc"
fi
chmod 600 "${ENV_FILE}" "${ENV_ENC}"

echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  CRITICAL: BACK UP YOUR AGE KEY                             ║${NC}"
echo -e "${RED}║                                                              ║${NC}"
echo -e "${RED}║  Without this key, you CANNOT decrypt your secrets.         ║${NC}"
echo -e "${RED}║                                                              ║${NC}"
echo -e "${RED}║  Key location: ${AGE_KEY_FILE}  ║${NC}"
echo -e "${RED}║                                                              ║${NC}"
echo -e "${RED}║  Run this to display it:                                    ║${NC}"
echo -e "${RED}║    cat ~/.config/age/keys.txt                               ║${NC}"
echo -e "${RED}║                                                              ║${NC}"
echo -e "${RED}║  Copy the ENTIRE contents to your password manager.         ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
if [[ "${OPENCLAW_NON_INTERACTIVE:-}" != "1" ]]; then
  read -r -p "Press Enter after you've backed up your age key: "
fi
# In non-interactive mode: Claude fetches and displays the key separately (see CLAUDE.md Step 4b)

# ── Step 4: Set up compose directory ──────────────────────────────────────────
banner "Step 4/6: Set up compose directory"
mkdir -p "${COMPOSE_DIR}"
cp "${DEPLOY_DIR}/docker-compose.yml" "${COMPOSE_DIR}/docker-compose.yml"
cp "${DEPLOY_DIR}/.env" "${COMPOSE_DIR}/.env"
chmod 600 "${COMPOSE_DIR}/.env"
success "Compose directory ready at ${COMPOSE_DIR}"

# ~/compose/.env is necessarily plaintext at rest (Docker Compose requirement).
# Back it up. If you edit ~/compose/.env later (e.g., to add TELEGRAM_BOT_TOKEN),
# re-encrypt the archive with:
#   SOPS_AGE_KEY_FILE=~/.config/age/keys.txt \
#     sops --age=$(age-keygen -y ~/.config/age/keys.txt) \
#     -e ~/compose/.env > ~/openclaw-deploy/.env.enc
info "Note: ~/compose/.env is necessarily plaintext (Docker Compose requirement)."
info "  Back it up. Re-encrypt to ~/openclaw-deploy/.env.enc after any edits."

# ── Step 5: Set up OpenClaw config ────────────────────────────────────────────
banner "Step 5/6: Set up OpenClaw config"
mkdir -p "${HOME}/.openclaw/skills/video-implementer"
mkdir -p "${HOME}/.openclaw/skills/web-researcher"
chmod 700 "${HOME}/.openclaw"

# Patch openclaw.json: replace localhost:11434 with the actual Tailscale IP.
# Docker ports are bound to ${TAILSCALE_IP}, not 0.0.0.0, so localhost won't route to Ollama.
OC_TAILSCALE_IP=$(grep "^TAILSCALE_IP=" "${DEPLOY_DIR}/.env" | cut -d= -f2 || true)
OC_TAILSCALE_IP="${OC_TAILSCALE_IP:-localhost}"
sed "s|http://localhost:11434|http://${OC_TAILSCALE_IP}:11434|g" \
  "${DEPLOY_DIR}/openclaw/openclaw.json" > "${HOME}/.openclaw/openclaw.json"
chmod 600 "${HOME}/.openclaw/openclaw.json"

sed "s|__TAILSCALE_IP__|${OC_TAILSCALE_IP}|g" "${DEPLOY_DIR}/openclaw/SOUL.md" > "${HOME}/.openclaw/SOUL.md"
chmod 600 "${HOME}/.openclaw/SOUL.md"
cp "${DEPLOY_DIR}/openclaw/MEMORY.md" "${HOME}/.openclaw/MEMORY.md"
chmod 600 "${HOME}/.openclaw/MEMORY.md"

# Patch USER.md with real first name and timezone from .env (preserves the template with placeholders)
_FIRST_NAME=$(grep "^USER_FIRST_NAME=" "${DEPLOY_DIR}/.env" | cut -d= -f2 || true)
_TIMEZONE=$(grep "^TZ=" "${DEPLOY_DIR}/.env" | cut -d= -f2 || true)
_FIRST_NAME_ESC=$(printf '%s\n' "${_FIRST_NAME}" | sed 's/[&|\\]/\\&/g')
_TIMEZONE_ESC=$(printf '%s\n' "${_TIMEZONE}" | sed 's/[&|\\]/\\&/g')
sed -e "s|__USER_FIRST_NAME__|${_FIRST_NAME_ESC}|g" \
    -e "s|__TIMEZONE__|${_TIMEZONE_ESC}|g" \
    "${DEPLOY_DIR}/openclaw/USER.md" > "${HOME}/.openclaw/USER.md"
chmod 600 "${HOME}/.openclaw/USER.md"
cp "${DEPLOY_DIR}/openclaw/skills/video-implementer/SKILL.md" \
   "${HOME}/.openclaw/skills/video-implementer/SKILL.md"
cp "${DEPLOY_DIR}/openclaw/skills/web-researcher/SKILL.md" \
   "${HOME}/.openclaw/skills/web-researcher/SKILL.md"

success "OpenClaw config files installed to ~/.openclaw/"

# ── Step 6: Start Docker stack ────────────────────────────────────────────────
banner "Step 6/6: Start services"
cd "${COMPOSE_DIR}"

# Determine host to use for health checks: Docker ports are bound to TAILSCALE_IP
# (not 0.0.0.0), so localhost won't work once Tailscale is up.
HEALTH_HOST=$(grep "^TAILSCALE_IP=" "${COMPOSE_DIR}/.env" | cut -d= -f2 || true)
HEALTH_HOST="${HEALTH_HOST:-localhost}"
info "Health check host: ${HEALTH_HOST}"

# Pre-flight: verify all image tags exist before pulling anything
info "Verifying Docker image tags..."
verify_image_tags

COMPOSE_TS_IP=$(grep "^TAILSCALE_IP=" "${COMPOSE_DIR}/.env" | cut -d= -f2 || true)
if [[ -z "${COMPOSE_TS_IP}" ]]; then
  error "TAILSCALE_IP is empty in ${COMPOSE_DIR}/.env!"
  error "Docker ports would bind to 0.0.0.0 (all interfaces = public internet)."
  exit 1
fi
success "TAILSCALE_IP=${COMPOSE_TS_IP} — ports bound to Tailscale only"

if ! docker compose up -d; then
  error "Docker stack failed to start. Check logs with: docker compose logs"
  exit 1
fi
success "Docker stack started"

# Wait for services to be healthy (max 3 min)
info "Waiting for services to become healthy (up to 3 minutes)..."
TIMEOUT=180
ELAPSED=0
INTERVAL=10

while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
  # Count unhealthy/starting services
  UNHEALTHY=$(docker compose ps --format json 2>/dev/null \
    | python3 -c "
import sys, json
data = sys.stdin.read().strip()
if not data:
    print(99)
    sys.exit()
count = 0
for line in data.split('\n'):
    try:
        s = json.loads(line)
        h = s.get('Health', '')
        if h not in ('healthy', ''):
            count += 1
    except:
        pass
print(count)
" 2>/dev/null || echo "99")

  if [[ "${UNHEALTHY}" == "0" ]]; then
    success "All services healthy!"
    break
  fi

  echo -n "."
  sleep ${INTERVAL}
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ ${ELAPSED} -ge ${TIMEOUT} ]]; then
  warn "Timeout waiting for services — check with: docker compose ps"
fi

echo ""

# Critical: Ollama must be up before we try to pull models
if ! curl -sf "http://${HEALTH_HOST}:11434/api/tags" -o /dev/null; then
  error "Ollama is not reachable after ${TIMEOUT}s. Aborting."
  error "Check logs: docker compose logs ollama"
  exit 1
fi
success "Ollama verified healthy"

# Pull models in background
banner "Pulling Ollama models (background)"
OLLAMA_MODEL=$(grep "^OLLAMA_MODEL=" "${COMPOSE_DIR}/.env" | cut -d= -f2 || echo "mistral")
info "Pulling Ollama model: ${OLLAMA_MODEL} (background)"
docker exec ollama ollama pull "${OLLAMA_MODEL}" >>/tmp/ollama-pull.log 2>&1 \
  && touch /tmp/ollama-pull-success \
  || echo "PULL_FAILED" >> /tmp/ollama-pull.log &
disown $!
success "Model pull started in background — check: tail -f /tmp/ollama-pull.log"

MODELS_FILE="${DEPLOY_DIR}/openclaw/models.txt"
if [[ -f "${MODELS_FILE}" ]]; then
  while IFS= read -r model || [[ -n "${model}" ]]; do
    [[ -z "${model}" || "${model}" == \#* ]] && continue
    model="${model%% *}"  # strip inline comment and trailing whitespace (first word only)
    [[ -z "${model}" ]] && continue
    [[ "${model}" == "${OLLAMA_MODEL}" ]] && continue  # already pulling above
    info "Pulling Ollama model: ${model}"
    docker exec ollama ollama pull "${model}" >>/tmp/ollama-pull.log 2>&1 &
    disown $!
  done < "${MODELS_FILE}"
fi

# ── Install OpenClaw via npm ───────────────────────────────────────────────────
banner "Installing OpenClaw"

# Non-root users can't write to the system npm prefix (/usr/local).
# Configure a user-writable prefix before installing.
NPM_GLOBAL="${HOME}/.npm-global"
mkdir -p "${NPM_GLOBAL}"
npm config set prefix "${NPM_GLOBAL}"
export PATH="${NPM_GLOBAL}/bin:${PATH}"
if ! grep -q "npm-global" "${BASHRC}" 2>/dev/null; then
  {
    echo ""
    echo "# npm global prefix (user-writable)"
    echo 'export PATH="${HOME}/.npm-global/bin:${PATH}"'
  } >> "${BASHRC}"
fi
# Also add to ~/.profile so non-interactive SSH one-liners have openclaw in PATH
PROFILE="${HOME}/.profile"
if ! grep -q "npm-global" "${PROFILE}" 2>/dev/null; then
  {
    echo ""
    echo "# npm global prefix (user-writable)"
    echo 'export PATH="${HOME}/.npm-global/bin:${PATH}"'
  } >> "${PROFILE}"
fi
success "npm prefix configured: ${NPM_GLOBAL}"

npm install -g openclaw@latest || {
  error "npm install failed. Check: npm config get cache"
  exit 1
}
if ! command -v openclaw &>/dev/null; then
  error "openclaw binary not found after npm install. PATH: ${PATH}"
  exit 1
fi
success "OpenClaw $(openclaw --version) installed"

# Fix any unrecognized config keys that prevent startup
info "Running openclaw doctor --fix to strip unknown config keys..."
"${NPM_GLOBAL}/bin/openclaw" doctor --fix || true

# Configure gateway mode (local = connects to on-VPS Docker services)
"${NPM_GLOBAL}/bin/openclaw" config set gateway.mode local || true

# Install and start the openclaw gateway as a systemd user service
info "Installing openclaw gateway service..."
"${NPM_GLOBAL}/bin/openclaw" gateway install || {
  warn "openclaw gateway install failed — run manually after setup: openclaw gateway install"
}

"${NPM_GLOBAL}/bin/openclaw" doctor || warn "openclaw doctor reported issues — check output above"

# Install daily n8n workflow backup via a wrapper script.
# Using a script (not an inline cron command) avoids:
#   1. cron's minimal environment (DOCKER_HOST not set → rootless Docker not found)
#   2. fragile multiline cron entries with backslash continuation
BACKUP_SCRIPT="${HOME}/bin/n8n-backup.sh"
mkdir -p "${HOME}/bin"
cat > "${BACKUP_SCRIPT}" << EOF
#!/usr/bin/env bash
# Daily n8n workflow backup — run by cron, called as: ${BACKUP_SCRIPT}
set -euo pipefail
# DOCKER_HOST must be set explicitly; cron runs with a minimal environment.
export DOCKER_HOST="unix:///run/user/\$(id -u)/docker.sock"
mkdir -p "${HOME}/backups"
docker exec n8n n8n export:workflow --all --output=/tmp/n8n-workflows-backup.json 2>/dev/null
docker cp n8n:/tmp/n8n-workflows-backup.json \
  "${HOME}/backups/n8n-workflows-\$(date +%Y%m%d).json"
find "${HOME}/backups" -name 'n8n-workflows-*.json' -mtime +30 -delete
EOF
chmod +x "${BACKUP_SCRIPT}"
(crontab -l 2>/dev/null | grep -v "n8n-backup"; echo "0 2 * * * ${BACKUP_SCRIPT}") | crontab -
success "n8n daily backup cron installed → ${BACKUP_SCRIPT} (runs at 2am, keeps 30 days)"

# ── Status table ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Service Status:${NC}"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || docker compose ps

echo ""
echo -e "${BOLD}Quick health checks:${NC}"
echo ""

check_health() {
  local name="$1"
  local url="$2"
  local result
  result=$(curl -sf "${url}" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
  if [[ "${result}" =~ ^[23] ]]; then
    echo -e "  ${GREEN}✓${NC} ${name} (${url})"
  else
    echo -e "  ${YELLOW}?${NC} ${name} (${url}) — HTTP ${result}"
  fi
}

# /health doesn't exist on Whisper; /asr returns 405 for GET which means the service is up
whisper_http=$(curl -s -o /dev/null -w "%{http_code}" "http://${HEALTH_HOST}:9000/asr" 2>/dev/null || true)
[[ "${whisper_http}" =~ ^[0-9]{3}$ ]] \
  && echo -e "  ${GREEN}✓${NC} Whisper (http://${HEALTH_HOST}:9000/asr — HTTP ${whisper_http})" \
  || echo -e "  ${YELLOW}?${NC} Whisper (http://${HEALTH_HOST}:9000/asr) — not responding"
check_health "n8n"          "http://${HEALTH_HOST}:5678/healthz"
check_health "Uptime Kuma"  "http://${HEALTH_HOST}:3001"
check_health "Ollama"       "http://${HEALTH_HOST}:11434/api/tags"

sleep 2  # brief wait for immediate pull failures
if grep -q "PULL_FAILED" /tmp/ollama-pull.log 2>/dev/null; then
  warn "Mistral 7B pull may have failed — check: tail -20 /tmp/ollama-pull.log"
else
  info "Mistral 7B pull in progress — check: tail -f /tmp/ollama-pull.log"
fi

# ── Next steps ────────────────────────────────────────────────────────────────
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || grep TAILSCALE_IP "${COMPOSE_DIR}/.env" | cut -d= -f2 || echo "YOUR_TAILSCALE_IP")

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Setup complete! 3 browser steps remaining.                 ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Browser steps:${NC}"
echo ""
echo -e "  Service URLs (Tailscale-only):"
echo -e "    n8n:         http://${TAILSCALE_IP}:5678"
echo -e "    Uptime Kuma: http://${TAILSCALE_IP}:3001"
echo -e "    Ollama API:  http://${TAILSCALE_IP}:11434"
echo -e "    Whisper:     http://${TAILSCALE_IP}:9000"
echo ""
echo -e "  1. ${CYAN}n8n first run${NC}"
echo -e "     Open: http://${TAILSCALE_IP}:5678"
echo -e "     You'll be prompted to create your owner account (any email + password)"
echo ""
echo -e "  2. ${CYAN}Uptime Kuma${NC}"
echo -e "     Open: http://${TAILSCALE_IP}:3001"
echo -e "     Create account, add monitors."
echo ""
echo -e "  3. ${CYAN}Telegram bot (optional, if not done in onboarding)${NC}"
echo -e "     - Message @BotFather → /newbot → copy token"
echo -e "     - Edit ~/.openclaw/openclaw.json: add your bot token"
echo -e "     - Restart daemon: systemctl --user restart openclaw-gateway.service"
echo ""
echo -e "${BOLD}Security reminders:${NC}"
echo -e "  - Back up age key:  cat ~/.config/age/keys.txt"
echo -e "  - All services are private — only accessible via Tailscale"
echo ""
echo -e "  Tailscale IP: ${CYAN}${TAILSCALE_IP}${NC}"
echo ""
