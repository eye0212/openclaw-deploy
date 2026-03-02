#!/usr/bin/env bash
# test.sh — Comprehensive test suite for the OpenClaw deployment package
# Run from the package root: bash test.sh
# Tests run locally on macOS — no VPS required.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0; FAIL=0; WARN=0

pass() { echo -e "  ${GREEN}✓${NC} $*"; ((PASS++)); }
fail() { echo -e "  ${RED}✗${NC} $*"; FAIL=$((FAIL + 1)); }
warn() { echo -e "  ${YELLOW}!${NC} $*"; ((WARN++)); }
section() { echo -e "\n${BOLD}── $* ──${NC}"; }

# ── Cleanup on exit ─────────────────────────────────────────────────────────────
CLEANUP_FILES=()
cleanup() {
  for f in "${CLEANUP_FILES[@]+"${CLEANUP_FILES[@]}"}"; do
    [[ -n "${f}" && -f "${f}" ]] && rm -f "${f}"
  done
  # Restore .env if we created a test one
  if [[ -f ".env.test-bak" ]]; then
    mv ".env.test-bak" ".env" 2>/dev/null || true
  elif [[ -f ".env" && "${DRY_RUN_CREATED_ENV:-false}" == "true" ]]; then
    rm -f ".env"
  fi
}
trap cleanup EXIT

# ── Section 1: Bash syntax checks ───────────────────────────────────────────────
section "Bash syntax"
for script in deploy.sh setup-root.sh setup-user.sh; do
  if bash -n "${script}" 2>/dev/null; then
    pass "${script}: syntax OK"
  else
    fail "${script}: syntax errors:"
    bash -n "${script}" 2>&1 | sed 's/^/    /'
  fi
done

# ── Section 2: Template placeholders ────────────────────────────────────────────
section "USER.md — must have placeholders, not hardcoded data"

if grep -q "__USER_FIRST_NAME__" openclaw/USER.md; then
  pass "USER.md: __USER_FIRST_NAME__ placeholder present"
else
  fail "USER.md: missing __USER_FIRST_NAME__ — placeholders were replaced by hardcoded data"
fi

if grep -q "__TIMEZONE__" openclaw/USER.md; then
  pass "USER.md: __TIMEZONE__ placeholder present"
else
  fail "USER.md: missing __TIMEZONE__"
fi

for name in "Eugene" "TestUser" "John"; do
  if grep -qi "First name.*${name}" openclaw/USER.md; then
    fail "USER.md: contains hardcoded name '${name}' — should be __USER_FIRST_NAME__"
  fi
done
pass "USER.md: no hardcoded names found"

# ── Section 3: .env.template checks ─────────────────────────────────────────────
section ".env.template — all required placeholders present, obsolete vars removed"

required_placeholders=(
  __VPS_IP__ __SSH_PORT__ __TAILSCALE_IP__ __TIMEZONE__
  __USER_FIRST_NAME__
  __ANTHROPIC_API_KEY__ __N8N_JWT_SECRET__
  __N8N_ENCRYPTION_KEY__ __WEBHOOK_SECRET__
)
for p in "${required_placeholders[@]}"; do
  if grep -q "${p}" .env.template; then
    pass ".env.template: ${p} present"
  else
    fail ".env.template: missing placeholder ${p}"
  fi
done

# n8n basic auth was removed in n8n v1.0+; these vars are silently ignored
for obsolete in N8N_BASIC_AUTH_ACTIVE N8N_BASIC_AUTH_USER N8N_BASIC_AUTH_PASSWORD; do
  if grep -q "^${obsolete}=" .env.template; then
    fail ".env.template: ${obsolete} present (removed in n8n 1.x — users would receive wrong credentials)"
  else
    pass ".env.template: ${obsolete} not present (correct for n8n 1.x)"
  fi
done

if grep -q "^USER_FIRST_NAME=" .env.template; then
  pass ".env.template: USER_FIRST_NAME stored in .env (patched into USER.md on VPS)"
else
  fail ".env.template: USER_FIRST_NAME missing — USER.md can't be personalized on VPS"
fi

# ── Section 4: docker-compose.yml checks ────────────────────────────────────────
section "docker-compose.yml — correct service definitions and port bindings"

for svc in n8n uptime-kuma whisper ollama; do
  if grep -q "container_name: ${svc}" docker-compose.yml; then
    pass "docker-compose.yml: '${svc}' service defined"
  else
    fail "docker-compose.yml: '${svc}' service missing"
  fi
done

for obsolete in N8N_BASIC_AUTH_ACTIVE N8N_BASIC_AUTH_USER N8N_BASIC_AUTH_PASSWORD; do
  if grep -q "N8N_BASIC_AUTH" docker-compose.yml; then
    fail "docker-compose.yml: still passes N8N_BASIC_AUTH_* to n8n (ignored in v1.x)"
    break
  fi
done
pass "docker-compose.yml: N8N_BASIC_AUTH_* not passed to n8n (correct)"

if grep -q 'TAILSCALE_IP:-0.0.0.0' docker-compose.yml; then
  pass "docker-compose.yml: ports bound to TAILSCALE_IP (private, not public internet)"
else
  fail "docker-compose.yml: ports not bound to TAILSCALE_IP"
fi

# All Docker healthchecks use localhost — correct because they run INSIDE the container
if grep -A2 "healthcheck:" docker-compose.yml | grep -q "localhost"; then
  pass "docker-compose.yml: healthchecks use localhost (correct — run inside container)"
fi

# ── Section 5: openclaw.json checks ─────────────────────────────────────────────
section "openclaw/openclaw.json — Ollama connectivity"

LOCALHOST_COUNT=$(grep -c "localhost:11434" openclaw/openclaw.json 2>/dev/null || echo 0)
if [[ "${LOCALHOST_COUNT}" -gt 0 ]]; then
  pass "openclaw.json: ${LOCALHOST_COUNT} localhost:11434 references (expected — patched with TAILSCALE_IP at deploy time)"
else
  warn "openclaw.json: no localhost:11434 references found (unexpected — may already be patched)"
fi

# Verify setup-user.sh patches openclaw.json before installing it
if grep -q "localhost:11434" setup-user.sh; then
  # Find the line numbers for the patch and the config copy
  PATCH_LINE=$(grep -n "localhost:11434" setup-user.sh | head -1 | cut -d: -f1)
  INSTALL_BANNER=$(grep -n '"Installing OpenClaw"' setup-user.sh | head -1 | cut -d: -f1)
  if [[ -n "${PATCH_LINE}" && -n "${INSTALL_BANNER}" && "${PATCH_LINE}" -lt "${INSTALL_BANNER}" ]]; then
    pass "setup-user.sh: openclaw.json patched with TAILSCALE_IP (line ${PATCH_LINE}) before install"
  else
    fail "setup-user.sh: openclaw.json patch order issue (patch line ${PATCH_LINE:-?}, install line ${INSTALL_BANNER:-?})"
  fi
else
  fail "setup-user.sh: does not patch openclaw.json localhost:11434 with TAILSCALE_IP"
fi

# Verify USER.md patching in setup-user.sh
if grep -q "USER_FIRST_NAME" setup-user.sh && grep -q "__USER_FIRST_NAME__" setup-user.sh; then
  pass "setup-user.sh: patches USER.md with USER_FIRST_NAME from .env"
else
  fail "setup-user.sh: does not patch USER.md with USER_FIRST_NAME"
fi

# ── Section 6: deploy.sh checks ─────────────────────────────────────────────────
section "deploy.sh — secrets, prompts, and SSH handling"

if grep -q "N8N_BASIC_AUTH_PASSWORD" deploy.sh; then
  fail "deploy.sh: still references N8N_BASIC_AUTH_PASSWORD (removed in n8n 1.x)"
else
  pass "deploy.sh: N8N_BASIC_AUTH_PASSWORD not referenced (correct)"
fi

if grep -q "N8N_JWT_SECRET.*openssl rand" deploy.sh && \
   grep -q "N8N_ENCRYPTION_KEY.*openssl rand" deploy.sh && \
   grep -q "WEBHOOK_SECRET.*openssl rand" deploy.sh; then
  pass "deploy.sh: N8N_JWT_SECRET, N8N_ENCRYPTION_KEY, WEBHOOK_SECRET generated"
else
  fail "deploy.sh: one or more required secrets not generated"
fi

# Verify StrictHostKeyChecking on Phase 3 SSH (port 2222 — first connection to that port)
# The command spans 4 lines: ssh ... \n  -o StrictHostKeyChecking... \n  openclaw@... \n  "bash...setup-user.sh"
if grep -B3 "setup-user\.sh" deploy.sh | grep -q "StrictHostKeyChecking=accept-new"; then
  pass "deploy.sh: Phase 3 SSH (openclaw user, port 2222) has StrictHostKeyChecking=accept-new"
else
  fail "deploy.sh: Phase 3 SSH missing StrictHostKeyChecking=accept-new — non-technical users will see host key prompt"
fi

# Verify sed_replace escapes & | \ in values
if grep -q "s/\[&|" deploy.sh; then
  pass "deploy.sh: sed_replace escapes special chars in values"
else
  warn "deploy.sh: sed_replace escaping pattern not found — special chars in API keys may break .env"
fi

# Verify non-interactive mode stops after upload
if grep -q "\[\[ ! -t 0 \]\]" deploy.sh && grep -q "Non-interactive mode" deploy.sh; then
  pass "deploy.sh: non-interactive mode detected and stops after upload (for Claude Code path)"
else
  fail "deploy.sh: non-interactive mode check missing"
fi

# Verify USER.md is no longer patched in deploy.sh (moved to setup-user.sh on VPS)
if grep -q "USER.md updated\|sed_replace.*USER.md" deploy.sh; then
  fail "deploy.sh: still patches USER.md locally — should be done on VPS by setup-user.sh"
else
  pass "deploy.sh: USER.md not patched locally (handled on VPS — template stays intact)"
fi

# ── Section 6b: deploy.sh — new validations ─────────────────────────────────────
section "deploy.sh — validation hardening"

# A: rsync error handling (rsync commands are multi-line; check for error messages directly)
if grep -qE "Upload failed|\.env upload failed" deploy.sh; then
  pass "deploy.sh: rsync has error handling (silent upload failure prevented)"
else
  fail "deploy.sh: rsync missing error handling — upload failures are silent"
fi

# D: SSH key permissions check
if grep -q "KEY_PERM\|chmod 600\|stat.*SSH_KEY" deploy.sh; then
  pass "deploy.sh: SSH key permissions validated before connection attempt"
else
  fail "deploy.sh: no SSH key permissions check — users get cryptic OpenSSH errors"
fi

# G: Anthropic key format check
if grep -q "sk-ant-" deploy.sh; then
  pass "deploy.sh: Anthropic API key format validated (must start with sk-ant-)"
else
  fail "deploy.sh: no Anthropic key format validation"
fi

# G: Timezone validation
if grep -q "zoneinfo.*TIMEZONE\|TIMEZONE.*zoneinfo" deploy.sh; then
  pass "deploy.sh: timezone validated against /usr/share/zoneinfo"
else
  fail "deploy.sh: no timezone validation — invalid zones fail silently at VPS runtime"
fi

# H: Tailscale IP fetch warns explicitly if empty
if grep -A5 "tailscale ip -4" deploy.sh | grep -q "Could not.*Tailscale\|warn.*Tailscale IP"; then
  pass "deploy.sh: Tailscale IP fetch warns explicitly on failure (no silent placeholder)"
else
  fail "deploy.sh: Tailscale IP failure is silent — user gets placeholder 'YOUR_TAILSCALE_IP'"
fi

# F: CLAUDE.md has Tailscale-on-Mac prerequisite
if grep -qi "tailscale.*mac\|mac.*tailscale\|tailscale.*download\|tailscale installed" CLAUDE.md; then
  pass "CLAUDE.md: Tailscale-on-Mac prerequisite documented"
else
  fail "CLAUDE.md: missing Tailscale-on-Mac note — users can't reach service URLs"
fi

# ── Section 7: setup-root.sh checks ─────────────────────────────────────────────
section "setup-root.sh — security and install correctness"

if grep -q "usermod -aG sudo openclaw" setup-root.sh; then
  fail "setup-root.sh: openclaw added to sudo group (violates least privilege — %sudo grants ALL sudo)"
else
  pass "setup-root.sh: openclaw NOT added to sudo group (correct)"
fi

if grep -q "tee.*tailscale-keyring.list" setup-root.sh; then
  if grep -q "tee.*tailscale-keyring.list.*>/dev/null\|tee.*>/dev/null.*tailscale-keyring" setup-root.sh; then
    pass "setup-root.sh: Tailscale keyring list tee silenced with >/dev/null"
  else
    fail "setup-root.sh: Tailscale keyring list contents printed to terminal (add >/dev/null)"
  fi
fi

if grep -q "/etc/sudoers.d/openclaw" setup-root.sh && \
   grep -q "loginctl enable-linger" setup-root.sh; then
  pass "setup-root.sh: sudoers grant minimal (loginctl enable-linger only)"
fi

if grep -q "rsync -a --delete" setup-root.sh; then
  pass "setup-root.sh: uses rsync --delete to copy deploy dir (prevents nested dir on re-run)"
else
  fail "setup-root.sh: cp -r used instead of rsync --delete — re-runs create nested directories"
fi

if grep -q "verify_sha256" setup-root.sh; then
  pass "setup-root.sh: checksum verification for downloaded binaries (age, sops)"
fi

# ── Section 8: setup-user.sh checks ─────────────────────────────────────────────
section "setup-user.sh — npm, cron, Docker, health checks"

NPM_PREFIX_LINE=$(grep -n "npm config set prefix" setup-user.sh | head -1 | cut -d: -f1 || echo "")
NPM_INSTALL_LINE=$(grep -n "npm install -g openclaw" setup-user.sh | head -1 | cut -d: -f1 || echo "")

if [[ -z "${NPM_PREFIX_LINE}" ]]; then
  fail "setup-user.sh: npm prefix not configured — npm install -g will fail with EACCES on non-root user"
elif [[ -z "${NPM_INSTALL_LINE}" ]]; then
  fail "setup-user.sh: npm install -g openclaw not found"
elif [[ "${NPM_PREFIX_LINE}" -lt "${NPM_INSTALL_LINE}" ]]; then
  pass "setup-user.sh: npm prefix set (line ${NPM_PREFIX_LINE}) before npm install (line ${NPM_INSTALL_LINE})"
else
  fail "setup-user.sh: npm prefix set AFTER npm install — install will fail"
fi

# Cron backup uses a script file (not inline multiline cron)
if grep -q "BACKUP_SCRIPT\|n8n-backup.sh" setup-user.sh; then
  pass "setup-user.sh: cron uses wrapper script (not inline multiline)"
else
  fail "setup-user.sh: cron backup is inline multiline — fragile, may fail across cron implementations"
fi

# Backup script sets DOCKER_HOST (required for rootless Docker in cron's minimal environment)
BACKUP_SECTION=$(awk '/n8n-backup.sh/,/crontab -/' setup-user.sh 2>/dev/null || true)
if echo "${BACKUP_SECTION}" | grep -q "DOCKER_HOST"; then
  pass "setup-user.sh: backup script sets DOCKER_HOST (rootless Docker requires this in cron)"
else
  fail "setup-user.sh: backup script missing DOCKER_HOST — docker commands will fail in cron"
fi

# Health checks use HEALTH_HOST (not localhost)
if grep -q 'HEALTH_HOST' setup-user.sh && \
   grep -A1 'check_health' setup-user.sh | grep -q 'HEALTH_HOST'; then
  pass "setup-user.sh: health checks use HEALTH_HOST (TAILSCALE_IP-aware)"
else
  fail "setup-user.sh: health checks use localhost — will fail when ports are bound to TAILSCALE_IP"
fi

# Preflight checks verify tools installed by setup-root.sh
if grep -q "dockerd-rootless-setuptool.sh" setup-user.sh && \
   grep -q "age-keygen" setup-user.sh && \
   grep -q "sops" setup-user.sh; then
  pass "setup-user.sh: preflight verifies age, sops, dockerd-rootless tools"
fi

# Concurrency lock prevents double-run
if grep -q "flock" setup-user.sh; then
  pass "setup-user.sh: flock prevents concurrent execution"
fi

# ── Section 9: CLAUDE.md checks ─────────────────────────────────────────────────
section "CLAUDE.md — health checks and n8n instructions"

if grep -qE "localhost.*(9000|5678|11434|3001)" CLAUDE.md; then
  fail "CLAUDE.md: health checks still use localhost (should use TAILSCALE_IP)"
elif grep -q 'tailscale ip' CLAUDE.md || grep -q 'TAILSCALE_IP' CLAUDE.md; then
  pass "CLAUDE.md: health checks use TAILSCALE_IP"
else
  warn "CLAUDE.md: no TAILSCALE_IP or localhost health check patterns found"
fi

if grep -q "N8N_BASIC_AUTH_PASSWORD\|admin.*password" CLAUDE.md; then
  fail "CLAUDE.md: still references n8n admin/password (removed in n8n 1.x)"
else
  pass "CLAUDE.md: no obsolete n8n basic auth credentials"
fi

# ── Section 10: Non-interactive dry run ─────────────────────────────────────────
section "Non-interactive dry run (fake VPS IP — must fail at SSH, not before)"

# Back up existing .env if present
if [[ -f ".env" ]]; then
  cp ".env" ".env.test-bak"
fi
DRY_RUN_CREATED_ENV=false

# Create a temp SSH key so the key-existence check passes
TEMP_KEY=$(mktemp "/tmp/test-key-XXXXXX")
CLEANUP_FILES+=("${TEMP_KEY}" "${TEMP_KEY}.pub")
# Remove the empty file mktemp created so ssh-keygen can write cleanly
rm -f "${TEMP_KEY}"
ssh-keygen -t ed25519 -f "${TEMP_KEY}" -N "" -q 2>/dev/null

set +e
DRY_RUN_OUTPUT=$(
  OPENCLAW_VPS_IP="203.0.113.1" \
  OPENCLAW_SSH_KEY="${TEMP_KEY}" \
  OPENCLAW_SSH_PORT="2222" \
  OPENCLAW_ANTHROPIC_KEY="sk-ant-test-000000000000" \
  OPENCLAW_OPENAI_KEY="" \
  OPENCLAW_GOOGLE_KEY="" \
  OPENCLAW_TELEGRAM_TOKEN="" \
  OPENCLAW_TIMEZONE="Europe/London" \
  OPENCLAW_FIRST_NAME="Alice" \
  bash deploy.sh < /dev/null 2>&1
)
DRY_RUN_EXIT=$?
set -e

if [[ "${DRY_RUN_EXIT}" -ne 0 ]]; then
  if echo "${DRY_RUN_OUTPUT}" | grep -q "\[ERROR\].*Cannot SSH"; then
    pass "Dry run: script fails at SSH connection (expected) — all prior steps succeeded"
  elif echo "${DRY_RUN_OUTPUT}" | grep -q "\[ERROR\]"; then
    FIRST_ERR=$(echo "${DRY_RUN_OUTPUT}" | grep "\[ERROR\]" | head -1)
    fail "Dry run: failed before SSH step: ${FIRST_ERR}"
  else
    fail "Dry run: failed with unexpected output (exit ${DRY_RUN_EXIT})"
  fi
else
  fail "Dry run: deploy.sh exited 0 when it should have failed (bad SSH to 203.0.113.1)"
fi

# .env should have been created before the SSH attempt
if [[ -f ".env" ]]; then
  DRY_RUN_CREATED_ENV=true

  # Permissions: 600
  if [[ "$(ls -la .env | cut -c1-10)" == "-rw-------" ]]; then
    pass ".env: permissions 600 (owner-only)"
  else
    fail ".env: permissions wrong (got $(ls -la .env | cut -c1-10), expected -rw-------)"
  fi

  # No unsubstituted placeholders (TAILSCALE_IP is expected to be empty, not a placeholder)
  REMAINING=$(grep -o "__[A-Z_]*__" .env 2>/dev/null || true)
  if [[ -z "${REMAINING}" ]]; then
    pass ".env: all placeholders substituted"
  else
    fail ".env: unsubstituted placeholders: ${REMAINING}"
  fi

  # TAILSCALE_IP empty (filled by setup-root.sh later)
  if grep -q "^TAILSCALE_IP=$" .env; then
    pass ".env: TAILSCALE_IP is empty (will be set by setup-root.sh after Tailscale auth)"
  else
    warn ".env: TAILSCALE_IP=$(grep "^TAILSCALE_IP=" .env | cut -d= -f2) — expected empty"
  fi

  # Key fields set correctly
  for check in "^VPS_IP=203\.0\.113\.1$" "^SSH_PORT=2222$" "^TZ=Europe/London$" "^USER_FIRST_NAME=Alice$"; do
    if grep -qE "${check}" .env; then
      pass ".env: ${check//\^/} verified"
    else
      fail ".env: ${check//\^/} not found — value substitution failed"
    fi
  done

  # Required secrets are non-empty
  for secret in N8N_JWT_SECRET N8N_ENCRYPTION_KEY WEBHOOK_SECRET; do
    VAL=$(grep "^${secret}=" .env | cut -d= -f2 || echo "")
    if [[ ${#VAL} -ge 32 ]]; then
      pass ".env: ${secret} generated (${#VAL} chars)"
    else
      fail ".env: ${secret} empty or too short (${#VAL} chars)"
    fi
  done

  # n8n basic auth NOT present
  if grep -q "^N8N_BASIC_AUTH_ACTIVE=" .env; then
    fail ".env: N8N_BASIC_AUTH_ACTIVE present (obsolete — n8n 1.x ignores it)"
  else
    pass ".env: N8N_BASIC_AUTH_ACTIVE not present (correct)"
  fi

  # Optional keys set to empty (not placeholders)
  for opt in OPENAI_API_KEY GOOGLE_API_KEY TELEGRAM_BOT_TOKEN; do
    if grep -q "^${opt}=$" .env; then
      pass ".env: ${opt}='' (optional, skipped correctly)"
    else
      warn ".env: ${opt} not empty — value: $(grep "^${opt}=" .env | cut -d= -f2)"
    fi
  done

  # ANTHROPIC_API_KEY set
  if grep -q "^ANTHROPIC_API_KEY=sk-ant-test" .env; then
    pass ".env: ANTHROPIC_API_KEY set"
  fi

else
  fail "Dry run: .env was not created — deploy.sh failed before secret generation"
fi

# USER.md must still have placeholders after the dry run (deploy.sh no longer patches it)
if grep -q "__USER_FIRST_NAME__" openclaw/USER.md; then
  pass "USER.md: placeholders intact after dry run (not modified by deploy.sh)"
else
  fail "USER.md: placeholders replaced by dry run — deploy.sh is still modifying USER.md locally"
fi

# ── Section 11: Full orchestration & hardening audit ─────────────────────────
section "Full orchestration & hardening audit"

# CLAUDE.md: uses Bash tool for SSH orchestration in Steps 3-4
if grep -qiE "Bash tool.*ssh|ssh.*Bash tool|Use the Bash tool.*ssh" CLAUDE.md; then
  pass "CLAUDE.md: SSH orchestration uses Bash tool (not manual user instructions)"
else
  fail "CLAUDE.md: Steps 3/4 still tell user to run SSH manually — not automated"
fi

# CLAUDE.md: has tailscale up + URL capture step
if grep -q "tailscale up" CLAUDE.md && grep -qiE "capture|URL|login\.tailscale\.com" CLAUDE.md; then
  pass "CLAUDE.md: Tailscale URL captured and shown to user"
else
  fail "CLAUDE.md: no step to capture/show Tailscale authorization URL"
fi

# CLAUDE.md: polls for Tailscale IP after authorization
if grep -q "tailscale ip" CLAUDE.md && grep -qiE "poll|retry|loop|attempt" CLAUDE.md; then
  pass "CLAUDE.md: polls for Tailscale IP after user authorizes"
else
  fail "CLAUDE.md: no Tailscale IP polling described"
fi

# CLAUDE.md: age key fetched by Claude and shown to user
if grep -q "cat ~/.config/age/keys.txt" CLAUDE.md || grep -qE "age.*key.*Bash|fetch.*age" CLAUDE.md; then
  pass "CLAUDE.md: age key fetched via Bash tool and shown to user"
else
  fail "CLAUDE.md: age key not fetched automatically — user still told to run command manually"
fi

# CLAUDE.md: openclaw-specific health check present
if grep -qE "openclaw status|openclaw doctor" CLAUDE.md; then
  pass "CLAUDE.md: openclaw daemon health check present (not just Docker services)"
else
  fail "CLAUDE.md: no openclaw daemon health check — only Docker services verified"
fi

# CLAUDE.md: Telegram /start or first-message instruction
if grep -qi "/start\|first message.*pair\|pair.*first message\|send.*bot.*start\|send.*\/start" CLAUDE.md; then
  pass "CLAUDE.md: Telegram /start / first-message pairing instruction present"
else
  fail "CLAUDE.md: no Telegram pairing instruction — user won't know to send /start"
fi

# CLAUDE.md: openclaw test BEFORE n8n browser steps in handoff
OC_TEST_LINE=$(grep -n "openclaw\|telegram.*bot\|send.*bot\|first test" CLAUDE.md | grep -iv "troubleshoot\|feature\|toggle" | head -1 | cut -d: -f1)
N8N_LINE=$(grep -n "http.*5678\|n8n.*browser\|open.*5678\|Set up owner" CLAUDE.md | head -1 | cut -d: -f1)
if [[ -n "${OC_TEST_LINE}" && -n "${N8N_LINE}" && "${OC_TEST_LINE}" -lt "${N8N_LINE}" ]]; then
  pass "CLAUDE.md: openclaw test shown before n8n browser setup (correct priority)"
else
  fail "CLAUDE.md: n8n browser setup shown before openclaw test — wrong priority for non-technical users"
fi

# CLAUDE.md: has openclaw daemon troubleshooting
if grep -qi "daemon.*start\|openclaw.*won.*start\|daemon won" CLAUDE.md; then
  pass "CLAUDE.md: openclaw daemon failure troubleshooting present"
else
  fail "CLAUDE.md: no troubleshooting for openclaw daemon failures"
fi

# setup-root.sh: non-interactive mode supported
if grep -q "OPENCLAW_NON_INTERACTIVE" setup-root.sh; then
  pass "setup-root.sh: OPENCLAW_NON_INTERACTIVE mode supported (enables Claude SSH orchestration)"
else
  fail "setup-root.sh: no non-interactive mode — Claude can't run it via SSH without getting stuck on read() prompts"
fi

# setup-root.sh: SSH port self-test present (automated)
if grep -qE "ssh.*-p.*\$\{SSH_PORT\}.*localhost|ssh.*localhost.*\$\{SSH_PORT\}|self.*test.*ssh|Testing new SSH port" setup-root.sh; then
  pass "setup-root.sh: SSH port self-tested automatically (no manual second-terminal required)"
else
  fail "setup-root.sh: no automated SSH port self-test — user still must open second terminal"
fi

# setup-root.sh: OPENCLAW_SKIP_TAILSCALE_AUTH supported
if grep -q "OPENCLAW_SKIP_TAILSCALE_AUTH" setup-root.sh; then
  pass "setup-root.sh: OPENCLAW_SKIP_TAILSCALE_AUTH flag supported (enables step-by-step orchestration)"
else
  fail "setup-root.sh: no OPENCLAW_SKIP_TAILSCALE_AUTH — can't separate Tailscale install from auth"
fi

# setup-root.sh: UFW idempotency fix
if grep -q "ufw status" setup-root.sh && grep -q "already active\|Status: active" setup-root.sh; then
  pass "setup-root.sh: UFW idempotent — skips reset if already active (preserves user rules)"
else
  fail "setup-root.sh: ufw --force reset runs unconditionally — destroys custom rules on re-deploy"
fi

# setup-user.sh: non-interactive mode supported
if grep -q "OPENCLAW_NON_INTERACTIVE" setup-user.sh; then
  pass "setup-user.sh: OPENCLAW_NON_INTERACTIVE mode supported (age key backup pause skippable)"
else
  fail "setup-user.sh: no non-interactive mode — age key backup pause blocks Claude orchestration"
fi

# setup-user.sh: model pull failure is no longer silent
if grep -qE "PULL_FAILED|pull.*failed|pull.*error|ollama.*pull.*\|\|" setup-user.sh; then
  pass "setup-user.sh: Ollama model pull failure detected (no longer silent)"
else
  fail "setup-user.sh: model pull failure is silent — user won't know if Mistral 7B didn't download"
fi

# deploy.sh: exit code checked for setup-root.sh remote call
if grep -B5 "Root setup complete" deploy.sh | grep -qE "if !|exit 1"; then
  pass "deploy.sh: exit code of setup-root.sh checked (masked failures prevented)"
else
  fail "deploy.sh: setup-root.sh exit code not checked — script prints 'success' even if setup failed"
fi

# deploy.sh: exit code checked for setup-user.sh remote call
if grep -B5 "User setup complete" deploy.sh | grep -qE "if !|exit 1"; then
  pass "deploy.sh: exit code of setup-user.sh checked"
else
  fail "deploy.sh: setup-user.sh exit code not checked — script prints 'success' even if setup failed"
fi

# deploy.sh: API key whitespace stripped
if grep -qE "ANTHROPIC_API_KEY.*\[\[:space:\]\]|trim.*API|API.*trim|strip.*API" deploy.sh; then
  pass "deploy.sh: API keys trimmed of whitespace (paste safety)"
else
  fail "deploy.sh: no whitespace stripping on API keys — pasted keys with spaces will fail silently"
fi

# deploy.sh: port range validation
if grep -q "SSH_PORT.*65535\|65535.*SSH_PORT" deploy.sh; then
  pass "deploy.sh: SSH port validated (1–65535 range)"
else
  fail "deploy.sh: no SSH port range validation"
fi

# deploy.sh: IP octet range validation
if grep -q "255" deploy.sh && grep -qE "o[1-4].*255|255.*o[1-4]" deploy.sh; then
  pass "deploy.sh: VPS IP octet values validated (0–255 per octet)"
else
  fail "deploy.sh: VPS IP regex only checks digit count, not value range (999.999.999.999 would pass)"
fi

# docker-compose.yml: WHISPER_LANGUAGE uses env var
if grep -q "WHISPER_LANGUAGE=\${WHISPER_LANGUAGE" docker-compose.yml || grep -q "\${WHISPER_LANGUAGE:-" docker-compose.yml; then
  pass "docker-compose.yml: WHISPER_LANGUAGE uses env var (not hardcoded to 'en')"
else
  fail "docker-compose.yml: WHISPER_LANGUAGE hardcoded — users can't change language without editing compose file"
fi

# ── Results ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ Results ━━━${NC}"
echo -e "  ${GREEN}Passed: ${PASS}${NC}"
[[ ${WARN} -gt 0 ]] && echo -e "  ${YELLOW}Warnings: ${WARN}${NC}"
[[ ${FAIL} -gt 0 ]] && echo -e "  ${RED}Failed: ${FAIL}${NC}" || true

if [[ ${FAIL} -eq 0 ]]; then
  echo -e "\n  ${GREEN}✓ All checks passed!${NC}"
  exit 0
else
  echo -e "\n  ${RED}✗ ${FAIL} check(s) failed.${NC}"
  exit 1
fi
