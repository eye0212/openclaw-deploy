#!/usr/bin/env bash
# deploy.sh — Mac-side coordinator for OpenClaw VPS deployment
# Run this from your Mac to configure and upload the deployment package
# Usage: bash ~/Desktop/openclaw-deploy/deploy.sh

set -euo pipefail
umask 077  # Ensure new files (including .env) are not world-readable

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

# ── Locate deploy directory ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Check prerequisites ───────────────────────────────────────────────────────
banner "OpenClaw Deployment Setup"

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_FILE="/tmp/openclaw-deploy-$(date +%Y%m%d-%H%M%S).log"
exec 1> >(tee -a "${LOG_FILE}"); exec 2>&1
info "Logging to ${LOG_FILE}"

echo "This script will:"
echo "  1. Prompt for your VPS details and API keys"
echo "  2. Generate random secrets (locally, never sent to VPS in plaintext)"
echo "  3. Create .env from template"
echo "  4. Upload the deployment package to your VPS"
echo ""

for cmd in ssh rsync openssl sed; do
  if ! command -v "${cmd}" &>/dev/null; then
    error "Required command not found: ${cmd}"
    exit 1
  fi
done
success "Prerequisites OK"

# ── Collect inputs ────────────────────────────────────────────────────────────
banner "Configuration"

prompt_required() {
  local var_name="$1"
  local prompt_text="$2"
  local value=""
  if [[ ! -t 0 ]]; then
    error "Required variable '${var_name}' is not set (non-interactive mode)."
    error "Set the corresponding OPENCLAW_* env var. See CLAUDE.md for the full list."
    exit 1
  fi
  while [[ -z "${value}" ]]; do
    read -r -p "${prompt_text}: " value
    if [[ -z "${value}" ]]; then
      echo "  (required — please enter a value)"
    fi
  done
  printf -v "${var_name}" '%s' "${value}"
}

prompt_optional() {
  local var_name="$1"
  local prompt_text="$2"
  local default="$3"
  local value=""
  if [[ -t 0 ]]; then
    read -r -p "${prompt_text} [${default}]: " value
  fi
  printf -v "${var_name}" '%s' "${value:-${default}}"
}

prompt_secret() {
  local var_name="$1"
  local prompt_text="$2"
  local value=""
  if [[ ! -t 0 ]]; then
    error "Required secret '${var_name}' is not set (non-interactive mode)."
    error "Set the corresponding OPENCLAW_* env var. See CLAUDE.md for the full list."
    exit 1
  fi
  read -r -s -p "${prompt_text}: " value
  echo ""
  printf -v "${var_name}" '%s' "${value}"
}

prompt_secret_optional() {
  local var_name="$1"
  local prompt_text="$2"
  local value=""
  if [[ -t 0 ]]; then
    read -r -s -p "${prompt_text} (optional — press Enter to skip): " value
    echo ""
  fi
  printf -v "${var_name}" '%s' "${value}"
}

# VPS IP
echo ""
echo -e "${BOLD}── Your VPS IP Address ──${NC}"
echo "  The public IP of your server. Find it in your Hetzner / DigitalOcean / Vultr dashboard."
echo ""
VPS_IP="${OPENCLAW_VPS_IP:-}"
[[ -z "${VPS_IP}" ]] && prompt_required VPS_IP "  VPS IP"
if [[ ! "${VPS_IP}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  error "Invalid VPS IP address: '${VPS_IP}'. Expected IPv4 format (e.g., 10.0.0.1)."
  exit 1
fi
IFS='.' read -r o1 o2 o3 o4 <<< "${VPS_IP}"
if (( o1 > 255 || o2 > 255 || o3 > 255 || o4 > 255 )); then
  error "Invalid VPS IP: ${VPS_IP} — each octet must be 0–255"
  exit 1
fi

# SSH key
echo ""
echo -e "${BOLD}── SSH Key Path ──${NC}"
echo "  The private key you use to log into your server as root."
echo "  Default is ~/.ssh/id_ed25519 — change this if yours is elsewhere."
echo ""
SSH_KEY_PATH="${OPENCLAW_SSH_KEY:-}"
[[ -z "${SSH_KEY_PATH}" ]] && prompt_optional SSH_KEY_PATH "  SSH key path" "${HOME}/.ssh/id_ed25519"
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"  # Expand leading ~ (env vars don't expand tilde in quotes)
if [[ ! -f "${SSH_KEY_PATH}" ]]; then
  if [[ ! -t 0 ]]; then
    error "SSH key not found at: ${SSH_KEY_PATH}"
    error "Set OPENCLAW_SSH_KEY to the correct path and try again."
    exit 1
  fi
  warn "SSH key not found at ${SSH_KEY_PATH}"
  prompt_required SSH_KEY_PATH "  Enter the correct path to your SSH key"
fi

if [[ "$(uname)" == "Darwin" ]]; then
  KEY_PERM=$(stat -f "%OLp" "${SSH_KEY_PATH}" 2>/dev/null || echo "")
else
  KEY_PERM=$(stat -c "%a" "${SSH_KEY_PATH}" 2>/dev/null || echo "")
fi
if [[ -n "${KEY_PERM}" && "${KEY_PERM}" != "600" && "${KEY_PERM}" != "400" ]]; then
  error "SSH key permissions are ${KEY_PERM} — OpenSSH will refuse a key that isn't 600."
  error "Fix it with: chmod 600 '${SSH_KEY_PATH}'"
  exit 1
fi

# SSH port
echo ""
echo -e "${BOLD}── SSH Port ──${NC}"
echo "  The port OpenClaw will use for SSH after setup (default: 2222 for security)."
echo ""
SSH_PORT="${OPENCLAW_SSH_PORT:-}"
[[ -z "${SSH_PORT}" ]] && prompt_optional SSH_PORT "  SSH port" "2222"
if ! [[ "${SSH_PORT}" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  error "Invalid SSH port: '${SSH_PORT}' — must be 1–65535"
  exit 1
fi
if (( SSH_PORT < 1024 )); then
  warn "Port ${SSH_PORT} is a privileged port (< 1024) — requires root. Recommend 2222."
fi

# Anthropic API key
echo ""
echo -e "${BOLD}── Anthropic API Key ──${NC}"
echo "  Powers the AI brain. Required."
echo "  Get yours at: console.anthropic.com → API Keys"
echo ""
ANTHROPIC_API_KEY="${OPENCLAW_ANTHROPIC_KEY:-}"
[[ -z "${ANTHROPIC_API_KEY}" ]] && prompt_secret ANTHROPIC_API_KEY "  Anthropic API key"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY//[[:space:]]/}"
if [[ -n "${ANTHROPIC_API_KEY}" && ! "${ANTHROPIC_API_KEY}" =~ ^sk-ant- ]]; then
  warn "Anthropic API key doesn't look right — it should start with 'sk-ant-'"
  warn "Double-check you copied the full key from console.anthropic.com"
fi

# Optional API keys
echo ""
echo -e "${BOLD}── OpenAI API Key (optional) ──${NC}"
echo "  For GPT-4 access. Press Enter to skip — you can add this later."
echo ""
if [[ "${OPENCLAW_OPENAI_KEY+set}" == "set" ]]; then
  OPENAI_API_KEY="${OPENCLAW_OPENAI_KEY}"
else
  prompt_secret_optional OPENAI_API_KEY "  OpenAI API key"
fi
OPENAI_API_KEY="${OPENAI_API_KEY//[[:space:]]/}"

echo ""
echo -e "${BOLD}── Google AI API Key (optional) ──${NC}"
echo "  For Gemini access. Press Enter to skip — you can add this later."
echo ""
if [[ "${OPENCLAW_GOOGLE_KEY+set}" == "set" ]]; then
  GOOGLE_API_KEY="${OPENCLAW_GOOGLE_KEY}"
else
  prompt_secret_optional GOOGLE_API_KEY "  Google AI API key"
fi
GOOGLE_API_KEY="${GOOGLE_API_KEY//[[:space:]]/}"

echo ""
echo -e "${BOLD}── Telegram Bot Token (optional) ──${NC}"
echo "  Lets you chat with OpenClaw via Telegram."
echo "  Get yours by messaging @BotFather on Telegram → /newbot"
echo ""
if [[ "${OPENCLAW_TELEGRAM_TOKEN+set}" == "set" ]]; then
  TELEGRAM_BOT_TOKEN="${OPENCLAW_TELEGRAM_TOKEN}"
else
  prompt_secret_optional TELEGRAM_BOT_TOKEN "  Telegram bot token"
fi
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN//[[:space:]]/}"

# Timezone
echo ""
echo -e "${BOLD}── Timezone ──${NC}"
echo "  Used for scheduling and timestamps in workflows."
echo "  Examples: America/New_York, America/Los_Angeles, Europe/London, Asia/Tokyo"
echo ""
TIMEZONE="${OPENCLAW_TIMEZONE:-}"
[[ -z "${TIMEZONE}" ]] && prompt_optional TIMEZONE "  Timezone" "America/New_York"
if [[ -n "${TIMEZONE}" && ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
  warn "Timezone '${TIMEZONE}' not found in local TZ database."
  warn "Examples: America/New_York  Europe/London  Asia/Tokyo"
  warn "Find your zone: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones"
fi

# First name
echo ""
echo -e "${BOLD}── Your First Name ──${NC}"
echo "  OpenClaw uses this to personalize its responses to you."
echo ""
USER_FIRST_NAME="${OPENCLAW_FIRST_NAME:-}"
[[ -z "${USER_FIRST_NAME}" ]] && prompt_required USER_FIRST_NAME "  Your first name"

# ── Generate secrets locally ──────────────────────────────────────────────────
banner "Generating secrets"

N8N_JWT_SECRET=$(openssl rand -hex 32)
N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)
WEBHOOK_SECRET=$(openssl rand -hex 32)

success "N8N_JWT_SECRET generated"
success "N8N_ENCRYPTION_KEY generated"
success "WEBHOOK_SECRET generated"

# ── Create .env from template ─────────────────────────────────────────────────
banner "Creating .env"

TEMPLATE="${SCRIPT_DIR}/.env.template"
ENV_OUT="${SCRIPT_DIR}/.env"

if [[ ! -f "${TEMPLATE}" ]]; then
  error ".env.template not found at ${TEMPLATE}"
  exit 1
fi

cp "${TEMPLATE}" "${ENV_OUT}"

# Substitute all placeholders
# Using | as delimiter in sed to avoid conflicts with / in values like paths
sed_replace() {
  local key="$1"
  local value="$2"
  local target_file="${3:-${ENV_OUT}}"
  # Escape all sed replacement special chars: & (back-reference), | (delimiter), \ (escape)
  local escaped_value
  escaped_value=$(printf '%s\n' "${value}" | sed 's/[&|\\]/\\&/g')
  sed -i.bak "s|${key}|${escaped_value}|g" "${target_file}"
  rm -f "${target_file}.bak"
}

sed_replace "__VPS_IP__"             "${VPS_IP}"
sed_replace "__SSH_PORT__"           "${SSH_PORT}"
sed_replace "__TAILSCALE_IP__"       ""  # Filled in by setup-root.sh after Tailscale auth
sed_replace "__TIMEZONE__"           "${TIMEZONE}"
sed_replace "__USER_FIRST_NAME__"    "${USER_FIRST_NAME}"
sed_replace "__ANTHROPIC_API_KEY__"  "${ANTHROPIC_API_KEY}"
sed_replace "__OPENAI_API_KEY__"     "${OPENAI_API_KEY}"
sed_replace "__GOOGLE_API_KEY__"     "${GOOGLE_API_KEY}"
sed_replace "__TELEGRAM_BOT_TOKEN__" "${TELEGRAM_BOT_TOKEN}"
sed_replace "__N8N_JWT_SECRET__"      "${N8N_JWT_SECRET}"
sed_replace "__N8N_ENCRYPTION_KEY__"  "${N8N_ENCRYPTION_KEY}"
sed_replace "__WEBHOOK_SECRET__"      "${WEBHOOK_SECRET}"

chmod 600 "${ENV_OUT}"
success ".env created at ${ENV_OUT}"
# USER.md is patched on the VPS by setup-user.sh using USER_FIRST_NAME and TZ from .env.
# This keeps openclaw/USER.md as a re-usable template (placeholders intact) on the Mac.

# ── Upload to VPS ─────────────────────────────────────────────────────────────
banner "Uploading to VPS"

info "Testing SSH connection to ${VPS_IP}..."
if ! SSH_ERR=$(ssh -i "${SSH_KEY_PATH}" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
     -o BatchMode=yes \
     root@"${VPS_IP}" "echo 'SSH OK'" 2>&1); then
  error "Cannot SSH to root@${VPS_IP}"
  error "SSH error: ${SSH_ERR}"
  echo "  Check:"
  echo "  - VPS IP is correct: ${VPS_IP}"
  echo "  - SSH key is authorized: ${SSH_KEY_PATH}"
  echo "  - VPS is running"
  exit 1
fi
success "SSH connection OK"

info "Uploading deployment package..."
rsync -az --progress \
  --exclude=".git" \
  --exclude="*.bak" \
  --exclude=".env" \
  -e "ssh -i '${SSH_KEY_PATH}'" \
  "${SCRIPT_DIR}/" \
  "root@${VPS_IP}:/root/openclaw-deploy/" \
  || { error "Upload failed — check your SSH connection and try again."; exit 1; }

# Upload .env separately (the freshly generated one, mode 600)
rsync -az \
  -e "ssh -i '${SSH_KEY_PATH}'" \
  "${ENV_OUT}" \
  "root@${VPS_IP}:/root/openclaw-deploy/.env" \
  || { error ".env upload failed — the deployment package is incomplete."; exit 1; }

success "Package uploaded to root@${VPS_IP}:/root/openclaw-deploy/"

# ── Non-interactive mode: stop after upload ───────────────────────────────────
if [[ ! -t 0 ]]; then
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║  Upload complete!                                            ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}n8n setup:${NC}"
  echo -e "  On first visit to http://YOUR_TAILSCALE_IP:5678 you'll create your owner account."
  echo ""
  echo -e "${YELLOW}Note:${NC} .env has been created locally at:"
  echo -e "  ${SCRIPT_DIR}/.env"
  echo -e "  Store this file securely or delete it after deployment."
  echo ""
  info "Non-interactive mode — skipping VPS SSH phases."
  info "See CLAUDE.md or README.md for VPS setup instructions."
  exit 0
fi

# ── Phase 2: VPS Root Setup ───────────────────────────────────────────────────
banner "Phase 2: VPS Root Setup"

echo "Before we SSH in, here's what to expect:"
echo ""
echo "  1. SSH safety check:"
echo "     The script will move SSH to port ${SSH_PORT} for security."
echo "     It will PAUSE and ask you to test the new port first."
echo "     When that happens:"
echo "       • Open a NEW terminal window (Cmd+T on Mac)"
echo "       • Run: ssh -p ${SSH_PORT} root@${VPS_IP}"
echo "       • If you see a login prompt: great! Go back and press Enter."
echo "       • If 'Connection refused': do NOT press Enter — come back here first."
echo ""
echo "  2. Tailscale authorization:"
echo "     A login URL will appear. Click it in your browser, log in to Tailscale,"
echo "     and authorize this device. Then come back here and press Enter."
echo ""
echo "  Everything else is fully automatic."
echo ""
read -r -p "Ready? Press Enter to begin VPS root setup..." _

if ! ssh -t -i "${SSH_KEY_PATH}" root@"${VPS_IP}" "bash /root/openclaw-deploy/setup-root.sh"; then
  error "Root setup failed — see output above for details"
  exit 1
fi
success "Root setup complete"

# ── Phase 3: VPS User Setup ───────────────────────────────────────────────────
banner "Phase 3: VPS User Setup"

echo "One more phase — setting up the openclaw user and starting all services."
echo "Here's what to expect:"
echo ""
echo "  1. Age encryption key backup:"
echo "     The script will generate an encryption key and PAUSE."
echo "     When it pauses, run this command and copy ALL the output to your password manager:"
echo "       cat ~/.config/age/keys.txt"
echo "     This key is needed to recover your secrets if anything goes wrong. Keep it safe."
echo "     Then press Enter to continue."
echo ""
echo "  2. OpenClaw onboarding wizard:"
echo "     Follow its prompts directly in the terminal."
echo ""
read -r -p "Ready? Press Enter to begin user setup..." _

if ! ssh -t -i "${SSH_KEY_PATH}" -p "${SSH_PORT}" \
  -o StrictHostKeyChecking=accept-new \
  openclaw@"${VPS_IP}" \
  "bash ~/openclaw-deploy/setup-user.sh"; then
  error "User setup failed — see output above for details"
  exit 1
fi
success "User setup complete"

# ── Phase 2c: Fetch Tailscale IP and print final summary ──────────────────────
banner "Deployment Complete"

TAILSCALE_IP=$(ssh -i "${SSH_KEY_PATH}" -p "${SSH_PORT}" \
  -o BatchMode=yes -o ConnectTimeout=10 \
  openclaw@"${VPS_IP}" \
  "tailscale ip -4 2>/dev/null || grep '^TAILSCALE_IP=' ~/compose/.env | cut -d= -f2" \
  2>/dev/null || echo "")

if [[ -z "${TAILSCALE_IP}" ]]; then
  warn "Could not automatically fetch your Tailscale IP."
  warn "Run this to get it: ssh -p ${SSH_PORT} openclaw@${VPS_IP} 'tailscale ip -4'"
  TAILSCALE_IP="YOUR_TAILSCALE_IP"
fi

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          OpenClaw is deployed! Here's your setup:               ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Your Tailscale IP: ${CYAN}${TAILSCALE_IP}${NC}"
echo ""
echo -e "${BOLD}Service URLs${NC} (open on any device with Tailscale installed):"
echo -e "  n8n (automation):     ${CYAN}http://${TAILSCALE_IP}:5678${NC}"
echo -e "  Uptime Kuma:          ${CYAN}http://${TAILSCALE_IP}:3001${NC}"
echo -e "  Ollama (local LLM):   ${CYAN}http://${TAILSCALE_IP}:11434${NC}"
echo -e "  Whisper (audio):      ${CYAN}http://${TAILSCALE_IP}:9000${NC}"
echo ""
echo -e "${BOLD}n8n first run:${NC}"
echo -e "  Open ${CYAN}http://${TAILSCALE_IP}:5678${NC} → you'll be prompted to create your owner account"
echo ""
echo -e "${BOLD}Browser steps to finish:${NC}"
echo -e "  1. Open ${CYAN}http://${TAILSCALE_IP}:5678${NC} — create your n8n owner account (email + password of your choice)"
echo -e "  2. Open ${CYAN}http://${TAILSCALE_IP}:3001${NC} — create your Uptime Kuma account"
if [[ -n "${TELEGRAM_BOT_TOKEN}" ]]; then
  echo -e "  3. Your Telegram bot is configured — message it to start chatting!"
else
  echo -e "  3. Telegram bot (optional): add later by editing ~/compose/.env on the VPS"
fi
echo ""
echo -e "${YELLOW}Note:${NC} Mistral 7B is downloading in the background (~4 GB, ~20 min)."
echo -e "      Check progress:"
echo -e "      ${CYAN}ssh -p ${SSH_PORT} openclaw@${VPS_IP} 'docker exec ollama ollama list'${NC}"
echo ""
echo -e "${YELLOW}Note:${NC} .env has been created locally at:"
echo -e "  ${SCRIPT_DIR}/.env"
echo -e "  Store this file securely or delete it after deployment."
echo ""
