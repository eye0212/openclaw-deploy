#!/usr/bin/env bash
# setup-root.sh — VPS root provisioning for OpenClaw
# Run as root on a fresh Ubuntu 22.04 VPS
# Usage: bash /root/openclaw-deploy/setup-root.sh

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

# ── Temp file cleanup ─────────────────────────────────────────────────────────
TMPFILES=()
cleanup() {
  if (( ${#TMPFILES[@]} > 0 )); then
    rm -rf "${TMPFILES[@]}"
  fi
}
trap cleanup EXIT INT TERM

# ── Helper: fetch latest GitHub release version ───────────────────────────────
get_github_release() {
  local repo="$1"
  local version
  version=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
  if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "Could not determine ${repo} version (got: '${version}'). Check network or GitHub API rate limit."
    return 1
  fi
  echo "${version}"
}

# ── Helper: verify SHA-256 checksum ──────────────────────────────────────────
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
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root."
  exit 1
fi

if [[ ! -f /root/openclaw-deploy/.env ]]; then
  error ".env not found at /root/openclaw-deploy/.env"
  error "Run deploy.sh from your Mac first to upload the package."
  exit 1
fi

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_FILE="/var/log/openclaw-root-setup.log"
exec 1> >(tee -a "${LOG_FILE}"); exec 2>&1
banner "OpenClaw Root Setup — $(date)"
info "Logging to ${LOG_FILE}"

DEPLOY_DIR="/root/openclaw-deploy"
SSH_PORT=$(grep "^SSH_PORT=" "${DEPLOY_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "2222")
VPS_IP=$(grep "^VPS_IP=" "${DEPLOY_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "YOUR_VPS_IP")

# ── Pre-flight resource checks ────────────────────────────────────────────────
banner "Pre-flight resource checks"

DISK_FREE_GB=$(df -BG / | awk 'NR==2 {gsub("G",""); print $4}')
if [[ "${DISK_FREE_GB}" -lt 20 ]]; then
  error "Insufficient disk space: ${DISK_FREE_GB} GB free (need ≥ 20 GB for Docker images + models)."
  exit 1
elif [[ "${DISK_FREE_GB}" -lt 50 ]]; then
  warn "Disk space is low: ${DISK_FREE_GB} GB free. Recommended ≥ 50 GB."
else
  success "Disk space: ${DISK_FREE_GB} GB free"
fi

FREE_RAM_MB=$(free -m | awk '/^Mem:/ {print $7}')
if [[ "${FREE_RAM_MB}" -lt 2000 ]]; then
  error "Insufficient available RAM: ${FREE_RAM_MB} MB (need ≥ 2000 MB for Ollama + Whisper)."
  exit 1
fi
success "Available RAM: ${FREE_RAM_MB} MB"

# ── Step 1: System update ────────────────────────────────────────────────────
banner "Step 1/10: System update"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
success "System updated"

# ── Step 2: Install packages ─────────────────────────────────────────────────
banner "Step 2/10: Install packages"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  ufw fail2ban auditd \
  unattended-upgrades apt-listchanges \
  uidmap dbus-user-session \
  curl rsync git ffmpeg \
  lsb-release ca-certificates \
  gnupg2 apt-transport-https
success "Packages installed"

# ── Step 2b: Install Node.js 22 ──────────────────────────────────────────────
banner "Step 2b/10: Install Node.js 22"
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
success "Node.js $(node --version) installed"

# ── Step 2c: Docker apt repository + packages ─────────────────────────────────
banner "Step 2c/10: Docker (rootless prerequisites)"
if ! command -v dockerd &>/dev/null; then
  info "Setting up Docker apt repository..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli docker-ce-rootless-extras
  success "Docker CE packages installed (dockerd + rootless extras)"
else
  info "Docker (dockerd) already installed, skipping"
fi

# ── Step 2d: Install age (encryption tool) ────────────────────────────────────
banner "Step 2d/10: Install age"
if ! command -v age &>/dev/null; then
  AGE_VERSION=$(get_github_release "FiloSottile/age") || exit 1
  ARCH=$(dpkg --print-architecture)
  case "${ARCH}" in
    amd64) AGE_ARCH="amd64" ;;
    arm64) AGE_ARCH="arm64" ;;
    *) error "Unsupported architecture: ${ARCH}"; exit 1 ;;
  esac
  AGE_BASE="https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}"
  AGE_TMP=$(mktemp -d); TMPFILES+=("${AGE_TMP}")
  TARBALL_NAME="age-v${AGE_VERSION}-linux-${AGE_ARCH}.tar.gz"
  curl -fsSL "${AGE_BASE}/${TARBALL_NAME}" -o "${AGE_TMP}/age.tar.gz"
  # checksums.txt not present in all releases — verify if available, skip with warning otherwise
  if curl -fsSL "${AGE_BASE}/checksums.txt" -o "${AGE_TMP}/checksums.txt" 2>/dev/null; then
    EXPECTED_HASH=$(grep "${TARBALL_NAME}" "${AGE_TMP}/checksums.txt" | awk '{print $1}')
    verify_sha256 "${AGE_TMP}/age.tar.gz" "${EXPECTED_HASH}" || {
      error "age download aborted due to checksum mismatch."
      exit 1
    }
    success "age v${AGE_VERSION} checksum verified"
  else
    warn "checksums.txt not available for age v${AGE_VERSION} — skipping checksum verification"
  fi
  tar -xzf "${AGE_TMP}/age.tar.gz" -C "${AGE_TMP}"
  install -m 755 "${AGE_TMP}/age/age" /usr/local/bin/age
  install -m 755 "${AGE_TMP}/age/age-keygen" /usr/local/bin/age-keygen
  success "age v${AGE_VERSION} installed"
else
  success "age already installed: $(age --version)"
fi

# ── Step 2e: Install sops (secrets manager) ───────────────────────────────────
banner "Step 2e/10: Install sops"
if ! command -v sops &>/dev/null; then
  SOPS_VERSION=$(get_github_release "getsops/sops") || exit 1
  ARCH=$(dpkg --print-architecture)
  SOPS_BASE="https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}"
  SOPS_BIN="sops-v${SOPS_VERSION}.linux.${ARCH}"
  SOPS_TMP=$(mktemp); TMPFILES+=("${SOPS_TMP}")
  curl -fsSL "${SOPS_BASE}/${SOPS_BIN}" -o "${SOPS_TMP}"
  # .sha256 file not present in all releases — verify if available, skip with warning otherwise
  SOPS_SHA_TMP=$(mktemp); TMPFILES+=("${SOPS_SHA_TMP}")
  if curl -fsSL "${SOPS_BASE}/${SOPS_BIN}.sha256" -o "${SOPS_SHA_TMP}" 2>/dev/null; then
    EXPECTED_HASH=$(awk '{print $1}' "${SOPS_SHA_TMP}")
    verify_sha256 "${SOPS_TMP}" "${EXPECTED_HASH}" || {
      error "sops download aborted due to checksum mismatch."
      exit 1
    }
    success "sops v${SOPS_VERSION} checksum verified"
  else
    warn "sops sha256 not available for v${SOPS_VERSION} — skipping checksum verification"
  fi
  install -m 755 "${SOPS_TMP}" /usr/local/bin/sops
  success "sops v${SOPS_VERSION} installed"
else
  success "sops already installed: $(sops --version | head -1)"
fi

# ── Step 3: Create openclaw user ──────────────────────────────────────────────
banner "Step 3/10: Create openclaw user"
if id openclaw &>/dev/null; then
  info "User 'openclaw' already exists, skipping creation"
else
  useradd -m -s /bin/bash openclaw
  success "User 'openclaw' created"
fi
# Minimal sudo grant: only what setup-user.sh needs (loginctl for rootless Docker linger)
# Do NOT add openclaw to the sudo group — that would grant full sudo via %sudo in /etc/sudoers.
echo "openclaw ALL=(root) NOPASSWD: /usr/bin/loginctl enable-linger openclaw" \
  > /etc/sudoers.d/openclaw
chmod 440 /etc/sudoers.d/openclaw
success "openclaw user configured"

# ── Step 4: Copy SSH authorized_keys ─────────────────────────────────────────
banner "Step 4/10: SSH authorized_keys"
if [[ -f /root/.ssh/authorized_keys ]]; then
  mkdir -p /home/openclaw/.ssh
  cp /root/.ssh/authorized_keys /home/openclaw/.ssh/authorized_keys
  chown -R openclaw:openclaw /home/openclaw/.ssh
  chmod 700 /home/openclaw/.ssh
  chmod 600 /home/openclaw/.ssh/authorized_keys
  success "Copied authorized_keys to openclaw"
else
  warn "No /root/.ssh/authorized_keys found — you must add your public key to /home/openclaw/.ssh/authorized_keys manually"
fi

# ── Step 5: Harden SSH ────────────────────────────────────────────────────────
banner "Step 5/10: Harden SSH config"
cat > /etc/ssh/sshd_config.d/99-openclaw.conf << SSHCONF
# OpenClaw hardened SSH config
Port ${SSH_PORT}
Protocol 2

# Key types
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
PubkeyAcceptedKeyTypes ssh-ed25519,rsa-sha2-512,rsa-sha2-256
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org

# Authentication
PasswordAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AllowUsers openclaw root

# Sessions
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2

# Forwarding
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding local
PermitTunnel no

# Misc
PrintLastLog yes
Banner none
SSHCONF

success "SSH config written to /etc/ssh/sshd_config.d/99-openclaw.conf"

# ── Step 6: UFW firewall ───────────────────────────────────────────────────────
banner "Step 6/10: Configure UFW"
if ufw status | grep -q "Status: active"; then
  info "UFW already active — skipping reset, re-applying rules"
else
  ufw --force reset
fi
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp comment 'OpenClaw SSH'
# Tailscale interface (allowed after install)
success "UFW rules set (port ${SSH_PORT} open)"

# ── Step 7: SSH safety check ───────────────────────────────────────────────────
banner "Step 7/10: SSH safety check"
info "Testing new SSH port ${SSH_PORT} from within the server..."
if timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
     -p "${SSH_PORT}" root@localhost exit 2>/dev/null; then
  success "SSH port ${SSH_PORT} verified — proceeding to enable firewall"
else
  # Automated test via loopback may not work on all systems; fall back to interactive check
  if [[ "${OPENCLAW_NON_INTERACTIVE:-}" != "1" ]]; then
    warn "Automated test inconclusive. Open a NEW terminal and run:"
    warn "  ssh -p ${SSH_PORT} root@${VPS_IP}"
    read -r -p "Press Enter when verified (or Ctrl+C to abort)..." _
  else
    warn "Could not self-verify SSH port ${SSH_PORT} via loopback."
    warn "Proceeding — check SSH access manually after setup."
  fi
fi

# Restart SSH first (before activating UFW) so port 22 stays accessible if it fails
# Ubuntu 24.04 uses ssh.service; older Ubuntu uses sshd.service — try both
systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || {
  error "SSH service restart failed — cannot proceed safely."
  exit 1
}
success "SSH service restarted on port ${SSH_PORT}"

# Enable UFW only after SSH is confirmed restarted
ufw --force enable
success "UFW enabled"

# ── Step 8: Unattended upgrades ───────────────────────────────────────────────
banner "Step 8/10: Unattended upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'UPGCONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
UPGCONF

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UUGCONF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}";
  "${distro_id}:${distro_codename}-security";
  "${distro_id}ESMApps:${distro_codename}-apps-security";
  "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
UUGCONF
success "Unattended upgrades configured"

# ── Step 9: Tailscale ─────────────────────────────────────────────────────────
banner "Step 9/10: Install Tailscale"

if command -v tailscale &>/dev/null; then
  info "Tailscale already installed: $(tailscale version | head -1)"
else
  info "Installing Tailscale via official apt repository..."
  # Use official apt repo (more robust than pipe-to-bash, signed packages)
  curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list \
    | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tailscale
  success "Tailscale installed"
fi

if [[ "${OPENCLAW_SKIP_TAILSCALE_AUTH:-}" == "1" ]]; then
  success "Tailscale installed — authentication will be handled separately"
else
  echo ""
  info "Starting Tailscale — authorize in your browser when prompted..."
  tailscale up

  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  Open the Tailscale auth URL above in your browser.         ║${NC}"
  echo -e "${CYAN}║  Authorize this machine to your Tailscale account.          ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  if [[ "${OPENCLAW_NON_INTERACTIVE:-}" != "1" ]]; then
    if ! read -r -t 600 -p "Press Enter after authorizing Tailscale in the browser: "; then
      error "Timed out. Re-run setup-root.sh after authorizing Tailscale."
      exit 1
    fi
  fi

  # Get Tailscale IP with retry (Tailscale can take a few seconds to initialize)
  TAILSCALE_IP=""
  info "Waiting for Tailscale IP..."
  for _i in $(seq 1 12); do
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
    if [[ -n "${TAILSCALE_IP}" ]]; then
      break
    fi
    sleep 5
  done

  if [[ -z "${TAILSCALE_IP}" ]]; then
    warn "Could not detect Tailscale IP after 60s — you'll need to set TAILSCALE_IP in .env manually"
    warn "Run: sed -i \"s|TAILSCALE_IP=.*|TAILSCALE_IP=\$(tailscale ip -4)|g\" ${DEPLOY_DIR}/.env"
  else
    success "Tailscale IP: ${TAILSCALE_IP}"
    # Patch .env — escape IP for sed (IPv4 only, but be safe)
    ESCAPED_IP=$(printf '%s\n' "${TAILSCALE_IP}" | sed 's/[&|\\]/\\&/g')
    sed -i "s|TAILSCALE_IP=.*|TAILSCALE_IP=${ESCAPED_IP}|g" "${DEPLOY_DIR}/.env"
    sed -i "s|WEBHOOK_URL=.*|WEBHOOK_URL=http://${ESCAPED_IP}:5678/|g" "${DEPLOY_DIR}/.env"
    success "TAILSCALE_IP patched into .env"
  fi
fi

# Allow Tailscale interface through UFW
ufw allow in on tailscale0
success "UFW: Tailscale interface allowed"

# ── Step 10: Security hardening ────────────────────────────────────────────────
banner "Step 10/10: Security hardening"

# Kernel hardening
cat > /etc/sysctl.d/99-openclaw.conf << 'SYSCTL'
# Network hardening
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Memory/exec hardening
kernel.randomize_va_space = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
SYSCTL

sysctl --system -q
success "Kernel hardening applied"

# auditd rules
cat > /etc/audit/rules.d/openclaw.rules << 'AUDITRULES'
# OpenClaw audit rules
-D
-b 8192
-f 1

# Watch authentication events
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers

# SSH config changes
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config

# Privileged commands
-a always,exit -F arch=b64 -S execve -F euid=0 -k exec_root
-a always,exit -F arch=b64 -S ptrace -k ptrace

# Network connections
-a exit,always -F arch=b64 -S connect -k network_connect
AUDITRULES

systemctl enable --now auditd
success "auditd configured and started"

# fail2ban
cat > /etc/fail2ban/jail.local << F2B
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
destemail = root@localhost
sendername = Fail2Ban
backend = systemd

[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 24h
F2B

systemctl enable --now fail2ban
success "fail2ban configured and started"

# ── Copy deploy dir to openclaw home ─────────────────────────────────────────
banner "Transferring files to openclaw"
# Use rsync --delete so re-runs replace (not nest) the directory
rsync -a --delete "${DEPLOY_DIR}/" /home/openclaw/openclaw-deploy/
chown -R openclaw:openclaw /home/openclaw/openclaw-deploy
success "Deployment files copied to /home/openclaw/openclaw-deploy"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Root setup complete!                                        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Next steps:"
echo ""
echo -e "  1. Switch to the openclaw user:"
echo -e "     ${CYAN}su - openclaw${NC}"
echo ""
echo -e "  2. Run the user setup script:"
echo -e "     ${CYAN}bash ~/openclaw-deploy/setup-user.sh${NC}"
echo ""
echo -e "  Or from your Mac:"
echo -e "     ${CYAN}ssh -p ${SSH_PORT} openclaw@$(tailscale ip -4 2>/dev/null || echo 'YOUR_TAILSCALE_IP')${NC}"
echo ""
echo -e "${YELLOW}Security note:${NC} Once setup-user.sh completes successfully, the sudo"
echo -e "  grant is no longer needed. You can remove it with:"
echo -e "     ${CYAN}rm /etc/sudoers.d/openclaw${NC}"
echo ""
