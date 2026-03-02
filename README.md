# OpenClaw — Deploy Your AI Assistant

## Deploy in one command

```bash
bash ~/Desktop/openclaw-deploy/deploy.sh
```

The wizard asks you 9 questions, then handles everything — VPS setup, services,
AI models, and OpenClaw installation.

## Or open in Claude Code

Drag this folder into Claude Code. The AI guides you through setup conversationally,
explains every step, and handles all the technical details.

## What you'll need before starting

| Requirement | Why | Get it |
|-------------|-----|--------|
| Ubuntu 22.04 VPS (≥4 vCPU, 8 GB RAM, 80 GB disk) | Runs your AI stack | Hetzner CX32 (~€10/mo) |
| SSH access to VPS as root | Initial setup | Provided by your VPS host |
| Tailscale account (free) | Private network | tailscale.com |
| Anthropic API key | Powers the AI | console.anthropic.com |
| Telegram bot token (optional) | Chat interface | @BotFather on Telegram |

## What gets deployed

| Service | Purpose | Port |
|---------|---------|------|
| OpenClaw | AI assistant gateway | — |
| n8n | Workflow automation | 5678 |
| Ollama + Mistral 7B | Local LLM (no API cost) | 11434 |
| Whisper | Audio transcription | 9000 |
| Uptime Kuma | Service monitoring | 3001 |

All services are **private** — only accessible via your Tailscale network.

---

## Manual deployment (advanced)

Use this if you prefer to run each step yourself instead of using the wizard.

### Pre-Deployment Checklist

Verify each item before running `deploy.sh`:

- [ ] **8 GB RAM** on VPS — required for Ollama (Mistral 7B) + Whisper simultaneously
- [ ] **50 GB disk free** — breakdown: ~4 GB Mistral model, ~150 MB Whisper cache, ~3 GB Docker images, headroom for n8n data
- [ ] **SSH access tested** — `ssh root@YOUR_VPS_IP` works from your Mac
- [ ] **Tailscale account created** at [tailscale.com](https://tailscale.com) (free tier is fine)
- [ ] **Anthropic API key** in hand (required; others are optional)

**Expected total time:** ~25 min interactive + ~20 min background (Mistral 7B pull)

**Disk space breakdown:**
- Mistral 7B model: ~4 GB
- Whisper base model cache: ~150 MB
- Docker images (all services): ~3 GB
- n8n workflow data: grows over time

### Step 1 — Run deploy.sh from your Mac

```bash
cd ~/Desktop/openclaw-deploy
bash deploy.sh
```

You'll be prompted for:
- VPS IP address
- SSH key path
- SSH port (default: 2222)
- API keys
- Your timezone and first name

The script generates secrets, fills in `.env`, and uploads everything to the VPS.

---

### Step 2 — Run setup-root.sh on the VPS (as root)

SSH into your VPS:
```bash
ssh root@YOUR_VPS_IP
cd /root/openclaw-deploy
bash setup-root.sh
```

This script:
- Runs pre-flight checks (disk space, RAM)
- Updates the system and installs dependencies
- Creates the `openclaw` user
- Hardens SSH (moves to port 2222)
- Configures UFW firewall
- Installs Tailscale

**IMPORTANT**: When prompted, open a second terminal and verify you can SSH on port 2222 before pressing Enter to restart sshd.

**Tailscale**: When the script prints the Tailscale auth URL, open it in your browser and authorize the device.

---

### Step 3 — Run setup-user.sh on the VPS (as openclaw)

```bash
su - openclaw
bash ~/openclaw-deploy/setup-user.sh
```

This script:
- Checks GitHub API connectivity and required tools (installed by setup-root.sh)
- Installs rootless Docker for the openclaw user
- Downloads Docker Compose plugin (with checksum verification)
- Generates an age encryption key and encrypts `.env` with sops
- Starts all Docker services
- Pulls Mistral 7B and nomic-embed-text models (background)

---

### Step 4 — Browser Steps

**a) n8n first run**
Open `http://TAILSCALE_IP:5678` in your browser. You'll see a "Set up owner account" form — enter your email and create a password. This becomes your n8n login.

**b) Uptime Kuma**
Open `http://TAILSCALE_IP:3001` and create an account. Add monitors using Docker service names (Uptime Kuma runs inside Docker and resolves service names via the internal network):
- Whisper health: `http://whisper:9000/health`
- n8n health: `http://n8n:5678/healthz`
- Ollama health: `http://ollama:11434/api/tags`

For host-level checks (run from the VPS shell, not Uptime Kuma):
- `curl http://localhost:9000/health` — Whisper
- `wget -qO- http://localhost:5678/healthz` — n8n

**c) Telegram bot** (optional)
1. Message `@BotFather` on Telegram
2. Send `/newbot` and follow prompts
3. Copy the bot token
4. Edit `~/compose/.env` on the VPS: add `TELEGRAM_BOT_TOKEN=your_token`
   (`~/compose/` is where `docker-compose.yml` and `.env` live after setup)
5. Restart the OpenClaw daemon: `openclaw restart`

---

## Post-Deploy Checklist

```bash
# Run these on the VPS as openclaw
# Docker ports are bound to the Tailscale IP — use TSIP, not localhost
TSIP=$(tailscale ip -4)
cd ~/compose
docker compose ps                                               # all services up?
curl -sf "http://${TSIP}:9000/health" -o /dev/null && echo "Whisper OK"
curl -sf "http://${TSIP}:5678/healthz" -o /dev/null && echo "n8n OK"
curl -sf "http://${TSIP}:3001/" -o /dev/null && echo "Uptime Kuma OK"
curl -sf "http://${TSIP}:11434/api/tags" -o /dev/null && echo "Ollama OK"
docker exec ollama ollama list                                  # mistral/nomic-embed-text listed?
sudo fail2ban-client status                                     # jails active?
sudo systemctl status auditd                                    # running?
sysctl net.ipv4.tcp_syncookies                                  # returns 1?
```

---

## After Deployment: Using OpenClaw

### Your first conversation

OpenClaw supports multiple interfaces — all are first-class:

| Interface | How to use | Best for |
|-----------|-----------|----------|
| **Telegram** | Message your bot directly | Day-to-day conversation |
| **CLI** | `openclaw "your message"` from VPS terminal | Quick queries, scripting |
| **REST API** | POST to the API endpoint | Integration with other tools |

**Quick start with Telegram** (if you provided a bot token during setup):
1. Open Telegram and find the bot you created
2. Send it: "Hello, are you there?"
3. OpenClaw responds within a few seconds

**Quick start via CLI:**
```bash
ssh -p 2222 openclaw@YOUR_TAILSCALE_IP
openclaw "What's the weather like today in New York?"
```

### What OpenClaw can do

| Task | How to trigger | Uses |
|------|---------------|------|
| Answer questions | Just ask | Anthropic Claude (default) |
| Research a URL | "Summarize this: [URL]" | web-researcher skill |
| Transcribe audio/video | Send file with "transcribe" | Whisper service |
| Code review | "Review this code: [code]" | capable (Claude Opus) profile |
| No-API-cost tasks | Automatic for simple queries | Mistral 7B via Ollama |

### n8n (optional — for automation power users)

n8n is **not required** for OpenClaw to work. It's pre-installed for users who want to build
advanced automations — for example, "when I receive an email matching X, ask OpenClaw to
summarize it and reply."

If you don't need automation workflows, you can ignore n8n entirely.
Access it at: `http://YOUR_TAILSCALE_IP:5678` (create your account on first visit)

---

## Managing Your Deployment

### Updating configuration after deployment

**The two config locations:**

| File | What it controls | Restart needed |
|------|-----------------|----------------|
| `~/compose/.env` (on VPS) | API keys, service ports, Docker settings | `cd ~/compose && docker compose restart` |
| `~/.openclaw/openclaw.json` (on VPS) | AI profiles, routing, channels | `openclaw restart` |
| `~/.openclaw/USER.md` (on VPS) | Your name, timezone, preferences | `openclaw restart` |
| `~/.openclaw/SOUL.md` (on VPS) | OpenClaw's personality | `openclaw restart` |

**Common tasks:**

*Enable Telegram (not set up during deployment):*
```bash
ssh -p 2222 openclaw@YOUR_TAILSCALE_IP
nano ~/compose/.env          # Set TELEGRAM_BOT_TOKEN=<token>
cd ~/compose && docker compose restart
```

*Add OpenAI or Google AI key:*
```bash
ssh -p 2222 openclaw@YOUR_TAILSCALE_IP
nano ~/compose/.env          # Set OPENAI_API_KEY=<key>
openclaw restart
```

*Switch to local AI (Ollama — no API cost):*
```bash
ssh -p 2222 openclaw@YOUR_TAILSCALE_IP
nano ~/.openclaw/openclaw.json   # Change "default_profile": "default" → "local"
openclaw restart
```

*Update USER.md (your preferences):*
```bash
ssh -p 2222 openclaw@YOUR_TAILSCALE_IP
nano ~/.openclaw/USER.md
openclaw restart
```

**Key distinction:** `openclaw restart` restarts only the OpenClaw daemon.
`docker compose restart` restarts the containerized services (n8n, Ollama, Whisper, Uptime Kuma).
Changes to `~/compose/.env` require `docker compose restart`, not `openclaw restart`.

---

## Monitoring & Alerting Setup

### Uptime Kuma Configuration

After creating your Uptime Kuma account at `http://TAILSCALE_IP:3001`:

1. **Add monitors** using Docker internal DNS names (not `localhost`):

   | Monitor Name  | URL                                  | Type |
   |---------------|--------------------------------------|------|
   | Whisper       | `http://whisper:9000/health`         | HTTP |
   | n8n           | `http://n8n:5678/healthz`            | HTTP |
   | Ollama        | `http://ollama:11434/api/tags`       | HTTP |
   | uptime-kuma   | `http://localhost:3001`              | HTTP |

2. **Recommended check interval**: 30 seconds for all services

3. **Add a notification channel** (Telegram recommended):
   - Go to Settings → Notifications → Add Notification
   - Choose Telegram; enter your bot token and chat ID
   - Test the notification before saving

4. **Disk space monitoring** — Uptime Kuma doesn't monitor disk natively. Schedule a cron check:
   ```bash
   # Add to openclaw's crontab (crontab -e):
   0 * * * * df -BG / | awk 'NR==2 && $4+0 < 10 {print "LOW DISK: "$4" free"}' | grep -q . && curl -s "https://api.telegram.org/bot${TOKEN}/sendMessage?chat_id=${CHAT_ID}&text=Low+disk+space+warning" || true
   ```

---

## Security Notes

- SSH is on **port 2222** (configurable) with key-only auth
- UFW blocks all inbound except the SSH port
- Tailscale provides a private network for service access
- Docker ports are bound to the Tailscale IP — not accessible from the public internet even if UFW is misconfigured
- Secrets are encrypted at rest using age + sops
- Fail2ban protects SSH
- auditd logs system calls
- Unattended upgrades handle security patches automatically

---

## Monthly Security Audit Checklist

Run these monthly to verify the security posture is intact:

```bash
# On the VPS as root or openclaw

# 1. Firewall rules
sudo ufw status verbose

# 2. SSH config unchanged
sudo grep -E '^Port|^PasswordAuthentication|^PermitRootLogin' /etc/ssh/sshd_config.d/99-openclaw.conf

# 3. fail2ban jails active
sudo fail2ban-client status
sudo fail2ban-client status sshd

# 4. auditd running
sudo systemctl is-active auditd

# 5. Container users (should not be root)
docker compose -f ~/compose/docker-compose.yml ps -q | xargs -I{} docker inspect {} --format '{{.Name}}: User={{.Config.User}}'

# 6. Secrets present in compose .env (verify secrets were generated)
grep -c 'API_KEY\|SECRET\|TOKEN\|PASSWORD' ~/compose/.env
# Should show ≥ 4 matching lines

# 7. Sudoers still narrow
sudo cat /etc/sudoers.d/openclaw
```

---

## Backup

Critical things to back up:

1. `~/.config/age/keys.txt` — without this you **cannot** decrypt `.env.enc`
2. `~/openclaw-deploy/.env.enc` — encrypted backup of all secrets
3. `~/compose/.env` — live plaintext secrets file (back up securely)
4. n8n workflows — export from the n8n UI: Settings → Import/Export

**Note on `~/compose/.env`**: This file must remain plaintext at rest because Docker Compose reads it directly. It is protected only by filesystem permissions (mode 600). Keep it backed up. If you edit it (e.g., add a Telegram token), re-encrypt to `.env.enc`:

```bash
SOPS_AGE_KEY_FILE=~/.config/age/keys.txt \
  sops --age=$(age-keygen -y ~/.config/age/keys.txt) \
  -e ~/compose/.env > ~/openclaw-deploy/.env.enc
```

---

## Disaster Recovery

### Restore .env from encrypted backup

```bash
# On the VPS, requires your age key
SOPS_AGE_KEY_FILE=~/.config/age/keys.txt \
  sops -d ~/openclaw-deploy/.env.enc > ~/compose/.env
chmod 600 ~/compose/.env
cd ~/compose && docker compose up -d
```

### Migrate to a new VPS

1. On your Mac, run `deploy.sh` with the new VPS IP — it re-uploads everything
2. On the new VPS, run `setup-root.sh` then `setup-user.sh`
3. Restore your age key: copy `~/.config/age/keys.txt` from a backup to the new VPS
4. Decrypt `.env.enc` → `~/compose/.env` (see above)
5. Import n8n workflows from your export

### Rotate a compromised API key

```bash
# Edit the plaintext .env
nano ~/compose/.env
# Change the relevant key (e.g., ANTHROPIC_API_KEY=sk-new-key)

# Restart affected service
cd ~/compose && docker compose restart openclaw

# Re-encrypt the backup
SOPS_AGE_KEY_FILE=~/.config/age/keys.txt \
  sops --age=$(age-keygen -y ~/.config/age/keys.txt) \
  -e ~/compose/.env > ~/openclaw-deploy/.env.enc
```

### Export n8n workflows

From the n8n UI: Settings → Import/Export → Export All Workflows. Store the JSON in a safe place.

### If your age key is lost

The age key is **not recoverable**. If lost:
- The plaintext `~/compose/.env` (if still present on the VPS) is your fallback
- Re-run `setup-user.sh` — it will generate a new age key and re-encrypt `.env`
- You will need to manually re-enter all API keys if `~/compose/.env` is also lost

---

## Troubleshooting

**Docker not found after install:**
```bash
source ~/.bashrc
export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock
```

**Service won't start / health checks failing:**
```bash
docker compose -f ~/compose/docker-compose.yml logs SERVICE_NAME
# e.g.: docker compose -f ~/compose/docker-compose.yml logs ollama
```

**Port already in use:**
```bash
# Find what's using the port (e.g., 5678)
sudo ss -tlnp | grep 5678
# Kill the process if needed
sudo kill $(sudo lsof -t -i:5678)
```

**SSH fails on port 2222:**
```bash
# Check sshd is listening
sudo ss -tlnp | grep 2222
# Check sshd status
sudo systemctl status sshd
# Check UFW rules
sudo ufw status
# Check key permissions (must be 600)
ls -la ~/.ssh/authorized_keys
```

**Docker Compose download failed / GitHub rate limited:**
```bash
# Check current rate limit status
curl -s https://api.github.com/rate_limit | python3 -c "import sys,json; r=json.load(sys.stdin)['rate']; print(f'Remaining: {r[\"remaining\"]}, resets: {r[\"reset\"]}')"
# Wait for reset (up to 1 hour) then re-run setup-user.sh
```

**Tailscale not connecting:**
```bash
sudo tailscale status
sudo tailscale up
```

**Tailscale IP not detected (TAILSCALE_IP missing from .env):**
```bash
# Set it manually after Tailscale connects
TSIP=$(tailscale ip -4)
sed -i "s|TAILSCALE_IP=.*|TAILSCALE_IP=${TSIP}|g" ~/openclaw-deploy/.env
sed -i "s|TAILSCALE_IP=.*|TAILSCALE_IP=${TSIP}|g" ~/compose/.env
```

**Mistral pull slow:** It's ~4 GB — check progress with:
```bash
docker exec ollama ollama list
# Shows "pulling" while in progress, model name once done
tail -f /tmp/ollama-pull.log
```

**"Lost age key":**
The age key at `~/.config/age/keys.txt` is irrecoverable if lost. The plaintext `~/compose/.env` on the VPS is your fallback for all secret values. See the Disaster Recovery section above.
