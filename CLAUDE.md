# OpenClaw Deployment Wizard

## ⚡ START HERE — Instructions for Claude Code

When this project is opened in Claude Code, **immediately** begin the deployment wizard.
Do not wait for the user to ask. Start with a friendly greeting that explains what
OpenClaw is and what you're about to deploy together, then start collecting information.

Never ask about plan approval or next steps — just proceed through the wizard steps
in order. The user is non-technical; explain everything in plain English.

Suggested opening:
> "Welcome! I'm going to help you deploy OpenClaw — your own private AI assistant
> running on a server you control. I'll ask you a few questions, then handle all
> the technical setup for you. This takes about 30 minutes total.
> Let's start with the basics."

---

## What You're Deploying

| Service | Purpose |
|---------|---------|
| OpenClaw | AI assistant gateway — your personal AI |
| n8n | Workflow automation (connects AI to apps) |
| Ollama + Mistral 7B | Local AI model — no API cost for basic tasks |
| Whisper | Audio transcription |
| Uptime Kuma | Service monitoring dashboard |

All services run privately — only accessible via Tailscale (a private network).
No ports are exposed to the public internet.

---

## Prerequisites

Before running deploy.sh, verify the user has all of these. Ask them to confirm each one:

- [ ] **VPS ready**: Ubuntu 22.04, at least 4 vCPU, 8 GB RAM, 80 GB disk
  - Recommended: Hetzner CX32 (~€10/month at hetzner.com)
- [ ] **SSH access as root**: They can run `ssh root@THEIR_VPS_IP` and get in
- [ ] **SSH key on their Mac**: Usually at `~/.ssh/id_ed25519` — if not, they need to create one
  - How to create: `ssh-keygen -t ed25519` and follow the prompts
- [ ] **Tailscale account**: Free at tailscale.com — must be created before setup
- [ ] **Anthropic API key**: Required. Get at console.anthropic.com → API Keys
- [ ] **Tailscale installed and logged in on your Mac**: Required to access any service URL
  after deployment — all services are private (Tailscale-only).
  - Download: tailscale.com/download
  - Log in with **the same Tailscale account** you'll authorize on the VPS
  - Without this, your Tailscale-only service URLs (n8n, Ollama, etc.) will not load
- [ ] **Emergency console access (do this first — required):** In Hetzner dashboard, go to
  your server → Rescue → Reset Root Password. Save that password in your password manager
  right now. This is your only way back in if SSH becomes inaccessible during setup — Hetzner
  VPS servers have no root password by default, so the web console login is unusable without it.
  If you skip this and get locked out, there is no recovery path other than the Hetzner rescue
  system (see Troubleshooting), which is significantly harder.

If any of these are missing, help the user get them before proceeding.

---

## Step 1: Collect Information

Use `AskUserQuestion` to collect information. Explain why each item is needed.
Store each answer to use in Step 2.

### Question 1: VPS IP Address
**Ask:** "What's the IP address of your server?"
**Context:** "This is the server where your AI assistant will live. It looks like four numbers separated by dots, e.g., 123.45.67.89"
**Where to find:** "Check your Hetzner / DigitalOcean / Vultr dashboard — it's listed next to your server"
**Validation:** Must match IPv4 format (e.g., 123.45.67.89). Reject anything that doesn't look like an IP address.
**Env var:** `OPENCLAW_VPS_IP`

### Question 2: SSH Key Path
**Ask:** "Where is your SSH key file? (The file you use to log into the server)"
**Context:** "This is a file on your Mac that proves you're allowed to access your server."
**Default:** `~/.ssh/id_ed25519` — tell the user to press Enter if they're not sure
**Where to find:** "It's usually at ~/.ssh/id_ed25519 on your Mac. You can check by running: ls ~/.ssh/"
**Note:** When setting `OPENCLAW_SSH_KEY` as an env var, use `$HOME/.ssh/id_ed25519` rather than
`~/.ssh/id_ed25519` — the tilde is not expanded by the shell inside quoted env var assignments.
deploy.sh auto-expands it, but using `$HOME` is safer and avoids any ambiguity.
**Env var:** `OPENCLAW_SSH_KEY`

### Question 3: SSH Port
**Ask:** "What SSH port should your server use after setup?"
**Context:** "For security, OpenClaw moves SSH off the default port 22. Port 2222 is the standard choice."
**Default:** 2222 — strongly recommend this unless they have a reason to change it
**Env var:** `OPENCLAW_SSH_PORT`

### Question 4: Anthropic API Key
**Ask:** "What's your Anthropic API key?"
**Context:** "This is what powers the AI brain. It starts with 'sk-ant-'"
**Where to find:** "Go to console.anthropic.com → click 'API Keys' in the left sidebar → create a new key"
**Validation:** Should start with `sk-ant-`
**Env var:** `OPENCLAW_ANTHROPIC_KEY`

### Question 5: OpenAI API Key (optional)
**Ask:** "Do you have an OpenAI API key you'd like to add? (This enables GPT-4 — you can skip this and add it later)"
**Context:** "Optional — lets OpenClaw use GPT-4 in addition to the local Mistral model."
**Where to find:** "platform.openai.com → API Keys"
**If skipped:** Set `OPENCLAW_OPENAI_KEY` to empty string `""`
**Env var:** `OPENCLAW_OPENAI_KEY`

### Question 6: Google AI API Key (optional)
**Ask:** "Do you have a Google AI API key for Gemini? (Optional — skip to add later)"
**Context:** "Optional — enables Gemini models."
**Where to find:** "aistudio.google.com → Get API Key"
**If skipped:** Set `OPENCLAW_GOOGLE_KEY` to empty string `""`
**Env var:** `OPENCLAW_GOOGLE_KEY`

### Question 7: Discord Bot Token (recommended)
**Ask:** "Do you want to control OpenClaw from Discord? If so, paste your Discord bot token here. (Strongly recommended — skip only if you don't use Discord)"
**Context:** "This lets you message your AI assistant from any device via a private Discord channel you control."
**Setup steps (do these before answering):**
1. Go to **discord.com/developers/applications** → New Application → name it "OpenClaw"
2. Left sidebar → **Bot** → click "Reset Token" → copy the token (shown once — save it)
3. On the same Bot page, enable **Message Content Intent** and **Server Members Intent** (scroll down to Privileged Gateway Intents)
4. Left sidebar → **OAuth2 → URL Generator** → Scopes: `bot` → Bot Permissions: Send Messages, Read Message History, View Channels, Embed Links, Attach Files, Add Reactions → copy the generated URL → open it → authorize it to your Discord server
5. In Discord: **Settings → Advanced → enable Developer Mode** (lets you copy IDs)
**If skipped:** Set `OPENCLAW_DISCORD_TOKEN` to empty string `""`
**Env var:** `OPENCLAW_DISCORD_TOKEN`

### Question 7b: Discord Server ID (if Discord token provided)
**Ask:** "What's your Discord server ID?"
**Where to find:** "Right-click your server name in Discord → Copy Server ID (requires Developer Mode enabled)"
**Skip if:** No Discord token provided. Set `OPENCLAW_DISCORD_SERVER_ID` to empty string `""`.
**Env var:** `OPENCLAW_DISCORD_SERVER_ID`

### Question 7c: Discord Channel Name (if Discord token provided)
**Ask:** "What Discord channel should OpenClaw use? (e.g., commands)"
**Context:** "Create a private channel in your server — e.g., #commands. Only messages in this channel will reach OpenClaw."
**Where to find:** "The channel name without the # — e.g., if it's #commands, enter: commands"
**Skip if:** No Discord token provided. Set `OPENCLAW_DISCORD_CHANNEL` to empty string `""`.
**Env var:** `OPENCLAW_DISCORD_CHANNEL`

### Question 7d: Your Discord User ID (if Discord token provided)
**Ask:** "What's your Discord user ID?"
**Where to find:** "Right-click your own username in Discord → Copy User ID (requires Developer Mode)"
**Context:** "This is your personal ID — OpenClaw will only respond to messages from you."
**Skip if:** No Discord token provided. Set `OPENCLAW_DISCORD_USER_ID` to empty string `""`.
**Env var:** `OPENCLAW_DISCORD_USER_ID`

### Question 8: Timezone
**Ask:** "What's your timezone?"
**Context:** "Used for scheduling and timestamps in your workflows."
**Default:** `America/New_York`
**Examples:** America/New_York, America/Los_Angeles, America/Chicago, Europe/London, Europe/Paris, Asia/Tokyo, Asia/Singapore, Australia/Sydney
**Env var:** `OPENCLAW_TIMEZONE`

### Question 9: First Name
**Ask:** "What's your first name? OpenClaw uses this to personalize its responses."
**Env var:** `OPENCLAW_FIRST_NAME`

---

## Step 2: Run deploy.sh

Once you have all 9 answers, run deploy.sh via the Bash tool with all `OPENCLAW_*` env vars set.

**Important:** Pass `< /dev/null` to ensure non-interactive mode — deploy.sh will automatically stop after uploading the package (it detects that stdin is not a TTY).

```
OPENCLAW_VPS_IP="<VPS_IP>" \
OPENCLAW_SSH_KEY="<SSH_KEY_PATH>" \
OPENCLAW_SSH_PORT="<SSH_PORT>" \
OPENCLAW_ANTHROPIC_KEY="<ANTHROPIC_KEY>" \
OPENCLAW_OPENAI_KEY="<OPENAI_KEY_or_empty>" \
OPENCLAW_GOOGLE_KEY="<GOOGLE_KEY_or_empty>" \
OPENCLAW_DISCORD_TOKEN="<DISCORD_TOKEN_or_empty>" \
OPENCLAW_DISCORD_SERVER_ID="<DISCORD_SERVER_ID_or_empty>" \
OPENCLAW_DISCORD_CHANNEL="<DISCORD_CHANNEL_NAME_or_empty>" \
OPENCLAW_DISCORD_USER_ID="<DISCORD_USER_ID_or_empty>" \
OPENCLAW_TIMEZONE="<TIMEZONE>" \
OPENCLAW_FIRST_NAME="<FIRST_NAME>" \
bash ~/Desktop/openclaw-deploy/deploy.sh < /dev/null
```

**What deploy.sh does:**
1. Validates all inputs
2. Generates random secrets (n8n passwords, encryption keys)
3. Creates a `.env` file locally
4. Uploads the complete deployment package to the VPS

**After it finishes:** proceed to Step 3. n8n uses its own account system (not pre-configured credentials) — the user will create their owner account on first visit to n8n.

If deploy.sh fails:
- SSH connection refused → see Troubleshooting section
- Invalid IP format → re-ask the user for their VPS IP
- SSH key not found → help user locate their key with `ls ~/.ssh/`

---

## Step 3: VPS Root Setup

Tell the user:
> "The package is uploaded. I'll now run the server setup automatically —
> this takes 5–10 minutes. In a moment I'll show you a Tailscale authorization
> link that you'll need to click once. Everything else is hands-free."

**3a: Run setup-root.sh non-interactively**

Before running, tell the user: "Step 1/4: Installing system packages, creating your user account, and moving SSH to port `<SSH_PORT>` for security. This takes 3–5 minutes..."

Use the Bash tool (SSH command):
```
ssh -i <SSH_KEY_PATH> \
  -o StrictHostKeyChecking=accept-new -o ConnectTimeout=60 \
  root@<VPS_IP> \
  "OPENCLAW_NON_INTERACTIVE=1 OPENCLAW_SKIP_TAILSCALE_AUTH=1 \
   bash /root/openclaw-deploy/setup-root.sh"
```

On success: "✓ System setup complete — packages installed, SSH secured on port `<SSH_PORT>`."
If it fails: "❌ System setup failed. Error: [last line of output]. See Troubleshooting below."
Do not proceed on failure.

**3b: Run `tailscale up` and capture the authorization URL**

Before running, tell the user: "Step 2/4: Connecting to your private Tailscale network. You'll need to click one authorization link in your browser."

Kill any stale `tailscale up` process first (multiple concurrent calls each get a different URL,
all of which are invalid except the most recent), then run `tailscale up`:
```
ssh -i <SSH_KEY_PATH> -p <SSH_PORT> \
  -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
  root@<VPS_IP> "pkill -f 'tailscale up' 2>/dev/null; tailscale up 2>&1"
```

Parse the output for a URL starting with `https://login.tailscale.com`.

If URL found, tell the user:
> "✋ One action needed from you:
>
> Click this link in your browser, log in to Tailscale with your account,
> and click 'Authorize':
> **[URL]**
>
> ⏱ You have about 10 minutes before this link expires.
>
> I'll wait and automatically detect when it's done — you don't need to tell me."

If no URL found (already authorized): skip to 3c with a note: "Tailscale already authorized."

**If the link expires before the user clicks it:** Run this to get a fresh one:
```
ssh -i <SSH_KEY_PATH> -p <SSH_PORT> root@<VPS_IP> "pkill -f 'tailscale up' 2>/dev/null; tailscale up 2>&1"
```

**3c: Poll for Tailscale IP (up to 5 minutes)**

Tell the user: "Waiting for Tailscale to confirm your authorization..."

Run in a retry loop (30 attempts, 10s apart) using the Bash tool:
```
for i in $(seq 1 30); do
  TS_IP=$(ssh -i <SSH_KEY_PATH> -p <SSH_PORT> root@<VPS_IP> "tailscale ip -4 2>/dev/null" 2>/dev/null || true)
  if [[ -n "$TS_IP" ]]; then echo "$TS_IP"; break; fi
  sleep 10
done
```

When it returns a valid IP: "✓ Tailscale connected! Your private IP is: `<TAILSCALE_IP>`"
If it times out after 5 minutes: "❌ Tailscale didn't connect. Please check you clicked the authorization link. Run this to try again: `ssh -p <SSH_PORT> root@<VPS_IP> 'tailscale up'`"

**3d: Write TAILSCALE_IP to .env and copy deploy dir to openclaw user**

Tell the user: "Step 3/4: Finalizing configuration..."

Use the Bash tool (SSH command):
```
ssh -i <SSH_KEY_PATH> -p <SSH_PORT> root@<VPS_IP> "
  TS=\$(tailscale ip -4)
  sed -i \"s|^TAILSCALE_IP=.*|TAILSCALE_IP=\${TS}|g\" /root/openclaw-deploy/.env
  rsync -a --delete /root/openclaw-deploy/ /home/openclaw/openclaw-deploy/
  chown -R openclaw:openclaw /home/openclaw/openclaw-deploy/
  echo Root setup complete. TAILSCALE_IP=\${TS}
"
```

On success: "✓ Configuration complete."

---

## Step 4: VPS User Setup

Tell the user:
> "Almost done! Step 4/4: Setting up your personal account and starting all
> services. This takes about 10 minutes. I'll pause once to show you an
> encryption key you need to save to your password manager."

**4a: Run setup-user.sh non-interactively**

Tell the user: "Installing Docker, OpenClaw, and starting all services (n8n, Ollama, Whisper)..."

Use the Bash tool (SSH command):
```
ssh -i <SSH_KEY_PATH> -p <SSH_PORT> \
  -o StrictHostKeyChecking=accept-new -o ConnectTimeout=120 \
  openclaw@<VPS_IP> \
  "OPENCLAW_NON_INTERACTIVE=1 bash ~/openclaw-deploy/setup-user.sh"
```

On success: "✓ Services started and OpenClaw installed."
If it fails: "❌ User setup failed at: [last line of output]. See Troubleshooting below."
Do not proceed on failure.

**4b: Fetch and show the age encryption key**

Tell the user: "⚠️  Important: I'm about to show you an encryption key. Please save it."

Use the Bash tool (SSH command):
```
ssh -i <SSH_KEY_PATH> -p <SSH_PORT> openclaw@<VPS_IP> "cat ~/.config/age/keys.txt"
```

Tell the user:
> "⚠️  Save this entire block to your password manager (1Password, Bitwarden, etc.) right now:
>
> ────────────────────────────
> [KEY CONTENTS — displayed verbatim]
> ────────────────────────────
>
> This key protects all your API keys and secrets. If it's lost and your VPS is
> ever rebuilt, you cannot recover them. It is NOT stored anywhere else.
>
> Once it's saved in your password manager, let me know and I'll continue."

Wait for user confirmation before proceeding.

**4c: Verify openclaw is running**

Tell the user: "Checking OpenClaw is healthy..."

Use the Bash tool (SSH command):
```
ssh -i <SSH_KEY_PATH> -p <SSH_PORT> openclaw@<VPS_IP> \
  "~/.npm-global/bin/openclaw status 2>&1 || ~/.npm-global/bin/openclaw doctor 2>&1"
```

On success: "✓ OpenClaw is running and healthy."
If issues: "⚠️  OpenClaw reported issues: [output]. See 'OpenClaw daemon won't start' below."

---

## Step 4.5: Configure Discord + Model Routing

**Skip this entire section if `OPENCLAW_DISCORD_TOKEN` is empty.**

Tell the user: "Setting up Discord and configuring smart model selection..."

**4.5a: Create API keys systemd override**

This injects API keys into the gateway process environment. The keys are NOT in the Docker
compose env — they're in a separate systemd drop-in file read only by the gateway service.

Use the Bash tool (SSH command), substituting actual key values from `OPENCLAW_*` env vars:
```
ssh -i <SSH_KEY_PATH> -p <SSH_PORT> openclaw@<VPS_IP> "
mkdir -p ~/.config/systemd/user/openclaw-gateway.service.d
cat > ~/.config/systemd/user/openclaw-gateway.service.d/api-keys.conf << 'EOF'
[Service]
Environment=ANTHROPIC_API_KEY=<ANTHROPIC_KEY>
Environment=OPENAI_API_KEY=<OPENAI_KEY_or_empty>
Environment=GOOGLE_API_KEY=<GOOGLE_KEY_or_empty>
EOF
chmod 600 ~/.config/systemd/user/openclaw-gateway.service.d/api-keys.conf
echo 'api-keys.conf written'
"
```

**4.5b: Enable Discord plugin**

```
ssh -i <SSH_KEY_PATH> -p <SSH_PORT> openclaw@<VPS_IP> \
  "~/.npm-global/bin/openclaw plugins enable discord 2>&1"
```

**4.5c: Write Discord channel config to openclaw.json**

Important config notes learned from deployment:
- `channels.discord.guilds` keys must use the **channel NAME** (e.g., "commands"), not the numeric channel ID
- `requireMention` must be set to `false` at both guild and channel level for the bot to respond without @-mention
- `groupPolicy: "allowlist"` means the bot only responds in explicitly listed guilds/channels
- The `allowFrom` list restricts which user IDs can send messages the bot will act on

Use the Bash tool (SSH command):
```
ssh -i <SSH_KEY_PATH> -p <SSH_PORT> openclaw@<VPS_IP> "
python3 -c \"
import json, sys

with open('/home/openclaw/.openclaw/openclaw.json') as f:
    cfg = json.load(f)

cfg['channels'] = {
    'discord': {
        'enabled': True,
        'token': '<DISCORD_TOKEN>',
        'groupPolicy': 'allowlist',
        'dmPolicy': 'pairing',
        'streaming': 'off',
        'allowFrom': ['<DISCORD_USER_ID>'],
        'guilds': {
            '<DISCORD_SERVER_ID>': {
                'requireMention': False,
                'channels': {
                    '<DISCORD_CHANNEL>': {
                        'requireMention': False
                    }
                },
                'users': ['<DISCORD_USER_ID>']
            }
        }
    }
}

cfg['plugins'] = cfg.get('plugins', {})
cfg['plugins']['entries'] = cfg['plugins'].get('entries', {})
cfg['plugins']['entries']['discord'] = {'enabled': True}

with open('/home/openclaw/.openclaw/openclaw.json', 'w') as f:
    json.dump(cfg, f, indent=2)
print('openclaw.json updated')
\"
"
```

**4.5d: Set default model and add aliases**

OpenClaw defaults to opus (expensive). Change default to sonnet with aliases for override:

```
ssh -i <SSH_KEY_PATH> -p <SSH_PORT> openclaw@<VPS_IP> "
~/.npm-global/bin/openclaw models set anthropic/claude-sonnet-4-6 2>&1 && \
~/.npm-global/bin/openclaw models aliases add fast anthropic/claude-haiku-4-5-20251001 2>&1 && \
~/.npm-global/bin/openclaw models aliases add capable anthropic/claude-opus-4-6 2>&1 && \
~/.npm-global/bin/openclaw models aliases add local ollama/mistral 2>&1
"
```

**4.5e: Reload systemd and restart gateway**

```
ssh -i <SSH_KEY_PATH> -p <SSH_PORT> openclaw@<VPS_IP> "
systemctl --user daemon-reload && \
systemctl --user restart openclaw-gateway.service && \
sleep 3 && \
~/.npm-global/bin/openclaw channels status 2>&1
"
```

Expected output: `discord: connected` or similar. If you see `discord: unresolved` or `channels: 0`, the token or channel name may be wrong.

On success: "✓ Discord connected! Test it: send any message in your #<DISCORD_CHANNEL> channel."

**Common Discord issues:**
- `channels unresolved: <serverID>/<channelID>` → you used a numeric channel ID instead of the channel name. Fix: ensure `<DISCORD_CHANNEL>` is the name (e.g., "commands"), not a number.
- `reason: no-mention` in logs → `requireMention` is true. Fix: re-run step 4.5c.
- Bot online but no response → API key not in gateway env. Fix: re-run step 4.5a and restart gateway.
- `Unknown channel: discord` → Discord plugin not enabled. Fix: re-run step 4.5b and restart.

---

## Step 5: Health Checks

Tell the user: "Running final health checks on all services..."

Run this via the Bash tool to verify all services are up:

```
ssh -i <SSH_KEY_PATH> -p <SSH_PORT> -o BatchMode=yes -o ConnectTimeout=10 openclaw@<VPS_IP> \
  "H=\$(tailscale ip -4 2>/dev/null || grep '^TAILSCALE_IP=' ~/compose/.env | cut -d= -f2); \
  cd ~/compose && docker compose ps --format 'table {{.Name}}\t{{.Status}}' && echo '---' && \
  curl -s -o /dev/null -w '%{http_code}' http://\${H}:9000/asr | grep -qE '^[0-9]{3}$' && echo 'Whisper: OK' && \
  curl -sf http://\${H}:5678/healthz -o /dev/null && echo 'n8n: OK' && \
  curl -sf http://\${H}:11434/api/tags -o /dev/null && echo 'Ollama: OK' && \
  curl -sf http://\${H}:3001/ -o /dev/null && echo 'Uptime Kuma: OK'"
```

Also check the OpenClaw daemon via the Bash tool:
```
ssh -i <SSH_KEY_PATH> -p <SSH_PORT> -o BatchMode=yes openclaw@<VPS_IP> \
  "~/.npm-global/bin/openclaw status 2>&1 || ~/.npm-global/bin/openclaw doctor 2>&1"
```

Also fetch the Tailscale IP:
```
ssh -i <SSH_KEY_PATH> -p <SSH_PORT> -o BatchMode=yes openclaw@<VPS_IP> \
  "tailscale ip -4 2>/dev/null || grep '^TAILSCALE_IP=' ~/compose/.env | cut -d= -f2"
```

After all checks, report each service clearly:
> ✓ Whisper: running
> ✓ n8n: running
> ✓ Ollama: running
> ✓ Uptime Kuma: running
> ✓ OpenClaw daemon: healthy
> (? Mistral 7B: still downloading in background — ~20 min)

If all services show "Up" and health checks pass, proceed to Step 6.

If any service is down, see the Troubleshooting section.

---

## Step 6: Hand Off

Give the user their complete setup summary.

Tell them:
> "You're all set! Here's everything you need:
>
> **Your Tailscale IP:** `<TAILSCALE_IP>`
>
> **Your first test:**
> 1. If you set up Discord: go to your Discord server, find your #<DISCORD_CHANNEL> channel,
>    and send any message. OpenClaw responds within a few seconds.
>    **Available model commands:**
>    - `/model fast` — switch to haiku (cheap, quick answers)
>    - `/model capable` — switch to opus (complex code, deep research)
>    - `/model sonnet` — switch back to default
>
> 2. CLI test (from your Mac — requires Tailscale running on your Mac):
>    `ssh -p <SSH_PORT> openclaw@<TAILSCALE_IP>`
>    `openclaw "Hello, are you there?"`
>
> (After confirming OpenClaw works, then set up n8n and Uptime Kuma below.)
>
> **Service URLs** (require Tailscale on your Mac — install at tailscale.com/download):
> - AI Workflows (n8n): http://<TAILSCALE_IP>:5678
> - Service Monitor: http://<TAILSCALE_IP>:3001
> - Local AI (Ollama): http://<TAILSCALE_IP>:11434
> - Audio (Whisper): http://<TAILSCALE_IP>:9000
>
> **Two browser steps to finish (after testing OpenClaw):**
> 1. Open http://<TAILSCALE_IP>:5678 — you'll see a "Set up owner account" form. Enter your email and create a password. This is your n8n login going forward.
> 2. Open http://<TAILSCALE_IP>:3001 — create your Uptime Kuma monitoring account
>
> **Note:** Mistral 7B (the local AI model) is downloading in the background — about 4 GB, takes ~20 min. You can check progress with:
> `ssh -p <SSH_PORT> openclaw@<VPS_IP> 'docker exec ollama ollama list'`"

**How to talk to OpenClaw:**

OpenClaw supports multiple interfaces:

- **Discord** (if you provided a bot token): Message OpenClaw in your private #<DISCORD_CHANNEL>
  channel. No @mention required. Switch models with `/model fast`, `/model capable`, `/model sonnet`.

- **CLI** (from the VPS terminal): SSH in, then run:
  `openclaw "Summarize this: https://example.com/article"`

- **REST API**: POST to `http://<TAILSCALE_IP>:<PORT>/api/message`
  (see openclaw documentation for endpoint details)

**Model routing:**
- Default: **claude-sonnet-4-6** — handles 95% of tasks at ~5x lower cost than opus
- `/model fast` → haiku (simple lookups, quick questions)
- `/model capable` → opus (complex coding, deep research)
- `/model local` → ollama/mistral (offline, free)

---

## Step 7: Research Pipeline Setup

**Prerequisites:** n8n owner account created (from Step 6), Tailscale running on Mac.

This step deploys the Smart Research Intake Pipeline — the automation that processes
URLs dropped in your Discord server.

### 7a: Get n8n API key

Go to http://<TAILSCALE_IP>:5678 → Settings (left sidebar) → n8n API → Create API key.
Copy the generated key (shown once).

### 7b: Create Discord webhooks

In Discord, right-click each channel → Edit Channel → Integrations → Webhooks → New Webhook → Copy Webhook URL:
- #drop-zone (create if it doesn't exist)
- #papers — for arxiv research cards
- #projects — for GitHub repo cards

### 7c: Run pipeline setup

SSH to VPS and run the setup script:
```
N8N_API_KEY="<paste key from 7a>" \
ANTHROPIC_API_KEY="<your Anthropic key>" \
BRAVE_API_KEY="<key from api.search.brave.com>" \
WEBHOOK_DROPZONE="<#drop-zone webhook URL>" \
WEBHOOK_PAPERS="<#papers webhook URL>" \
WEBHOOK_PROJECTS="<#projects webhook URL>" \
bash ~/openclaw-deploy/scripts/setup-n8n.sh
```

See `scripts/pipeline.env.example` for all available settings.

The script will:
1. Create Anthropic credential in n8n
2. Generate SSH key for n8n → VPS access
3. Deploy the research intake pipeline
4. Configure #drop-zone in OpenClaw to auto-trigger pipeline

**Test:** Drop `https://arxiv.org/abs/2408.09869` in your Discord #drop-zone channel.
You should see a paper card appear in #papers within 15 seconds.

### n8n 2.x Known Issues

If you rebuild the pipeline manually:
- Webhook node: add `webhookId` UUID at root level, not inside parameters
- Switch node: use typeVersion 3 with `mode: "rules"` (typeVersion 1 broken — routes all to output 0)
- SSH credential: RSA PEM key only (`ssh-keygen -t rsa -b 4096 -m PEM`)
- Anthropic API calls: strip `_meta` from request body
- `responseMode`: use `"onReceived"` not `"immediatelyAfterReceive"`

---

## Step 8: Social Media Pipeline — Instagram Session Setup

After the research pipeline is running (Step 7 complete), enable Instagram support by setting up
the `ig_fetch.py` script on the VPS. This lets you drop any Instagram post URL into `#drop-zone`
and have it automatically find the referenced paper or GitHub repo.

### 8a: Install instagrapi on VPS

```bash
ssh -p <SSH_PORT> openclaw@<VPS_IP> "curl -sS https://bootstrap.pypa.io/get-pip.py | python3 - --break-system-packages 2>&1 | tail -2 && python3 -m pip install --break-system-packages instagrapi 2>&1 | tail -3"
```

### 8b: Upload the fetch script and save credentials

```bash
mkdir -p ~/Desktop/openclaw-deploy/scripts  # already exists
scp -P <SSH_PORT> ~/Desktop/openclaw-deploy/scripts/ig_fetch.py openclaw@<VPS_IP>:~/scripts/ig_fetch.py
ssh -p <SSH_PORT> openclaw@<VPS_IP> "chmod +x ~/scripts/ig_fetch.py && mkdir -p ~/.config"

# Save Instagram burner account credentials
ssh -p <SSH_PORT> openclaw@<VPS_IP> 'python3 -c "
import json
open(\"/home/openclaw/.config/ig_creds.json\",\"w\").write(json.dumps({\"username\":\"BURNER_USERNAME\",\"password\":\"BURNER_PASSWORD\"}))
import os; os.chmod(\"/home/openclaw/.config/ig_creds.json\", 0o600)
print(\"saved\")
"'
```

Replace `BURNER_USERNAME` and `BURNER_PASSWORD` with your Instagram burner account credentials.

### 8c: First login — must be done from Mac (VPS IP is datacenter-blacklisted by Instagram)

Instagram blocks login attempts from datacenter IPs. Log in from your Mac once to create a session:

```bash
# Install instagrapi on Mac
pip3 install --break-system-packages instagrapi

# Run the login script
python3 ~/Desktop/openclaw-deploy/scripts/ig_login.py
```

The script reads `~/.config/ig_creds.json` and handles the login interactively.
Instagram may email a 6-digit verification code to the address on the burner account — enter it
when prompted. The script saves the session to `~/Desktop/ig_session.json`.

Copy the session to the VPS:
```bash
scp -P <SSH_PORT> ~/Desktop/ig_session.json openclaw@<VPS_IP>:~/.config/ig_session.json
```

### 8d: Test it

```bash
ssh -p <SSH_PORT> openclaw@<VPS_IP> \
  "PATH=\$PATH:/home/openclaw/.local/bin python3 ~/scripts/ig_fetch.py 'https://www.instagram.com/p/DTBQZu8jO2A/' 2>&1"
```

Should return JSON with a `caption` field. Then test end-to-end:
```bash
curl -X POST http://<TAILSCALE_IP>:5678/webhook/research-intake \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://www.instagram.com/p/DTBQZu8jO2A/"}'
```

A paper card should appear in `#papers` within 30 seconds.

### Session renewal (every ~90 days)

When Instagram invalidates the session, `ig_fetch.py` will return `{"error": "..."}`. Renew:
```bash
python3 ~/Desktop/openclaw-deploy/scripts/ig_login.py  # on Mac, enter verification code if prompted
scp -P <SSH_PORT> ~/Desktop/ig_session.json openclaw@<VPS_IP>:~/.config/ig_session.json
```

### What social media URLs are supported

| Platform | URL pattern | How it's fetched |
|----------|-------------|-----------------|
| Instagram posts/reels | `instagram.com/p/` or `/reel/` | `ig_fetch.py` (instagrapi mobile API) |
| Twitter/X | `twitter.com/` or `x.com/*/status/*` | HTTP GET + OG tag extraction |
| Bluesky | `bsky.app/profile/*/post/*` | HTTP GET + OG tag extraction |
| LinkedIn | `linkedin.com/posts/` or `/feed/updates/` | HTTP GET + OG tag extraction |

For all platforms: if the post caption contains a direct arxiv/GitHub URL, it's submitted at depth=1.
If not, Brave search is used with the best query Claude can form from the caption.
If nothing is found, a fallback summary card is posted to `#drop-zone`.

---

## Troubleshooting Reference

### SSH connection refused (deploy.sh fails at upload)
- Verify VPS IP is correct — check the dashboard again
- Verify SSH key path: `ls -la <SSH_KEY_PATH>`
- Test manually: `ssh -v root@<VPS_IP>` (note: default port 22 for initial connection)
- Check VPS is running in the dashboard

### SSH connection refused after root setup (port 2222)
- The SSH port change may not have taken effect
- Try connecting on port 22 still: `ssh root@<VPS_IP>`
- If that works: `sudo systemctl restart sshd` then try port 2222 again

### Tailscale not connecting
Run on VPS: `sudo tailscale status` — if it shows "needs login", run `sudo tailscale up` and re-authorize

### OpenClaw daemon won't start / not responding

Check daemon status:
```bash
ssh -p <SSH_PORT> openclaw@<VPS_IP> '~/.npm-global/bin/openclaw status 2>&1; ~/.npm-global/bin/openclaw doctor 2>&1'
```

Check logs:
```bash
ssh -p <SSH_PORT> openclaw@<VPS_IP> 'ls -la ~/.openclaw/logs/ && tail -50 ~/.openclaw/logs/*.log'
```

Restart the daemon:
```bash
ssh -p <SSH_PORT> openclaw@<VPS_IP> 'systemctl --user restart openclaw-gateway.service'
```

Verify Anthropic API key is valid (the most common cause):
```bash
ssh -p <SSH_PORT> openclaw@<VPS_IP> 'cat ~/.config/systemd/user/openclaw-gateway.service.d/api-keys.conf'
# Key must start with sk-ant- and be valid at console.anthropic.com
# Note: API keys for the gateway live in the systemd drop-in, NOT in ~/compose/.env
```

Re-run onboarding if needed:
```bash
ssh -p <SSH_PORT> openclaw@<VPS_IP> '~/.npm-global/bin/openclaw onboard'
```

If Discord bot is online but not responding:
1. Check the API key is in the gateway env (most common cause):
   `ssh -p <SSH_PORT> openclaw@<VPS_IP> 'cat ~/.config/systemd/user/openclaw-gateway.service.d/api-keys.conf'`
   If missing, re-run Step 4.5a and restart gateway.
2. Check Discord plugin is enabled:
   `ssh -p <SSH_PORT> openclaw@<VPS_IP> '~/.npm-global/bin/openclaw plugins list 2>&1 | grep discord'`
   Should show `discord: enabled`. If not, run `~/.npm-global/bin/openclaw plugins enable discord`.
3. Verify channel name in openclaw.json matches actual Discord channel name:
   `ssh -p <SSH_PORT> openclaw@<VPS_IP> 'cat ~/.openclaw/openclaw.json | python3 -m json.tool'`
   The key under `guilds.<serverID>.channels` must be the channel NAME (e.g., "commands"), not an ID.

### Service won't start / health check fails
```
ssh -p <SSH_PORT> openclaw@<VPS_IP> 'docker compose -f ~/compose/docker-compose.yml logs <SERVICE_NAME>'
```
Replace `<SERVICE_NAME>` with: `n8n`, `ollama`, `whisper`, or `uptime-kuma`

### Drop-zone says "Processing" but no card appears

1. Check gateway logs for the blocked URL error:
   `ssh -p <SSH_PORT> openclaw@<VPS_IP> 'journalctl --user -u openclaw-gateway.service -n 20'`
   If you see "Blocked hostname or private/internal/special-use IP address":
   The drop-zone systemPrompt needs to be updated to use exec+curl.
   Re-run Step 7c to fix.

2. Check n8n received the webhook:
   Go to http://<TAILSCALE_IP>:5678 → Executions
   If no execution appears, the webhook was never called.
   If execution appears but failed, check the execution detail for the error node.

3. Check the pipeline is active:
   n8n → Workflows → "Smart Research Intake" should show "Active" (green toggle)

### n8n can't be reached in browser
- Make sure Tailscale is running and logged in on your Mac
- Verify you're using the Tailscale IP (not the public VPS IP)
- Check n8n is up: `ssh -p <SSH_PORT> openclaw@<VPS_IP> 'docker compose -f ~/compose/docker-compose.yml ps n8n'`

### Mistral 7B pull slow or stalled
```
ssh -p <SSH_PORT> openclaw@<VPS_IP> 'docker exec ollama ollama list && tail -f /tmp/ollama-pull.log'
```
The model is ~4 GB — expect 15–30 minutes depending on VPS bandwidth.

### Adding features after deployment

**Add or change Discord bot:**
1. SSH: `ssh -p <SSH_PORT> openclaw@<VPS_IP>`
2. Edit: `nano ~/.openclaw/openclaw.json` → update the `channels.discord.token` value
3. Restart: `systemctl --user restart openclaw-gateway.service`

**Add OpenAI or Google AI key:**
1. SSH: `ssh -p <SSH_PORT> openclaw@<VPS_IP>`
2. Edit the gateway env drop-in: `nano ~/.config/systemd/user/openclaw-gateway.service.d/api-keys.conf`
   Add the line: `Environment=OPENAI_API_KEY=<key>` or `Environment=GOOGLE_API_KEY=<key>`
3. Reload and restart: `systemctl --user daemon-reload && systemctl --user restart openclaw-gateway.service`

Note: `~/compose/.env` is for Docker service config (n8n database, Ollama host, etc.) — it is NOT
read by the gateway process. API keys go in the systemd drop-in.

**Switch to local AI (Ollama/Mistral — no API cost):**
- In Discord: type `/model local`
- From CLI: `ssh -p <SSH_PORT> openclaw@<VPS_IP> '~/.npm-global/bin/openclaw models set ollama/mistral'`
- Then restart: `systemctl --user restart openclaw-gateway.service`

**Model routing reference:**
- Default model: `anthropic/claude-sonnet-4-6` (set in Step 4.5d)
- View current default: `~/.npm-global/bin/openclaw models status`
- Change default: `~/.npm-global/bin/openclaw models set <model>` then restart gateway
- List aliases: `~/.npm-global/bin/openclaw models aliases list`
- Add alias: `~/.npm-global/bin/openclaw models aliases add <name> <model>`

**Customize your personality and preferences:**
- `nano ~/.openclaw/USER.md` — who you are (name, timezone, preferences)
- `nano ~/.openclaw/SOUL.md` — OpenClaw's persona and communication style
- After editing either: `systemctl --user restart openclaw-gateway.service`

**Important:** After changing `~/compose/.env`, restart Docker services with
`cd ~/compose && docker compose restart`, not just `systemctl --user restart openclaw-gateway.service`.
The gateway service only restarts the OpenClaw daemon. Docker services read `.env`
at startup and need a full container restart to pick up changes.

### Resuming after a failed setup

**setup-root.sh failed before Step 7 (SSH/UFW):**
SSH is still on port 22. Safe to re-run as root on port 22:
```
ssh -i <SSH_KEY_PATH> root@<VPS_IP> "OPENCLAW_NON_INTERACTIVE=1 OPENCLAW_SKIP_TAILSCALE_AUTH=1 bash /root/openclaw-deploy/setup-root.sh"
```

**setup-root.sh failed at or after Step 7 (SSH port already changed):**
SSH is now on port `<SSH_PORT>`. Try:
```
ssh -i <SSH_KEY_PATH> -p <SSH_PORT> root@<VPS_IP>
```
If that also fails (UFW enabled before SSH restarted — the server lockout scenario):
use the Hetzner Rescue System below.

**setup-user.sh failed:**
SSH to the openclaw user on port `<SSH_PORT>`. Docker services may or may not be running.
Check: `docker compose -f ~/compose/docker-compose.yml ps`
setup-user.sh is safe to re-run — most steps are idempotent.

**Hetzner Rescue System (for SSH lockout — server completely inaccessible):**
1. Hetzner dashboard → your server → **Rescue** tab → Enable Rescue System (linux64)
2. Copy the temporary root password shown on screen
3. **Actions** → Power off → Power on (hard reset)
4. Wait 30 seconds, then: `ssh root@<VPS_IP>` using the temporary password
5. Mount the main disk: `mount /dev/sda1 /mnt`
6. Disable UFW so SSH is accessible on reboot:
   `sed -i 's/ENABLED=yes/ENABLED=no/' /mnt/etc/ufw/ufw.conf`
7. Reboot: `reboot`
8. Server comes back with UFW off — SSH should be accessible (try port 22 first, then `<SSH_PORT>`)
9. Re-enable UFW after confirming SSH works: `ufw enable`

### deploy.sh exits with "non-interactive mode" immediately
This is expected behavior when run via Claude Code (stdin is not a TTY). deploy.sh stops after upload intentionally. Proceed to Step 3 manually.

### "Age key" question
If the user asks what the age key is: "It's an encryption key that protects all your API keys and passwords stored on the server. Think of it like a master password for your secrets vault. Without it, you can't decrypt your secrets — that's why we backed it up."

---

## Step 9: Gmail + Google Calendar Integration

**Prerequisites:** Step 7 (n8n) complete, n8n owner account created, Tailscale running on Mac.

This step connects OpenClaw to Eugene's personal Gmail and Google Calendar.
Claude can then answer "check my email" or "what's on my calendar today?" from Discord.

Flow: Discord → Claude (Mac node) → exec+curl → n8n webhook → Gmail/Calendar API → reply

### 9a: Google Cloud Setup (Eugene does this in browser)

1. Go to **console.cloud.google.com** → Create a new project (or use existing)
2. In the project, go to **APIs & Services → Enable APIs** and enable both:
   - **Gmail API**
   - **Google Calendar API**
3. Go to **APIs & Services → OAuth consent screen** → External → fill in app name ("OpenClaw"), your email, save
4. Go to **APIs & Services → Credentials → Create Credentials → OAuth 2.0 Client ID**
   - Application type: **Web application**
   - Authorized redirect URI: `http://100.94.99.89:5678/rest/oauth2-credential/callback`
   - Click Create → copy the **Client ID** and **Client Secret**

### 9b: Create Gmail credential in n8n

1. Open http://<TAILSCALE_IP>:5678 → **Credentials** (left sidebar) → **Add credential**
2. Search for **"Gmail OAuth2"** → select it
3. Paste the OAuth Client ID and Client Secret from step 9a
4. Click **Connect** → complete the Google sign-in → authorize access
5. Click **Save** → copy the credential **ID** from the URL bar (looks like: `abc123XYZdef`)

### 9c: Create Google Calendar credential in n8n

1. Still in Credentials → **Add credential**
2. Search for **"Google Calendar OAuth2 API"** → select it
3. Paste the **same** OAuth Client ID and Client Secret
4. Click **Connect** → complete the Google sign-in → authorize access to calendar
5. Click **Save** → copy the credential **ID**

### 9d: Deploy Gmail Bridge workflow

Run from your Mac terminal (or from Claude Code):
```bash
N8N_API_KEY="<paste your n8n API key>" \
N8N_GMAIL_CRED_ID="<credential ID from step 9b>" \
python3 ~/Desktop/openclaw-deploy/scripts/build_gmail.py
```

To get your n8n API key: n8n → **Settings → n8n API → Create API key**

### 9e: Deploy Calendar Bridge workflow

```bash
N8N_API_KEY="<paste your n8n API key>" \
N8N_GCAL_CRED_ID="<credential ID from step 9c>" \
OPENCLAW_TIMEZONE="America/New_York" \
python3 ~/Desktop/openclaw-deploy/scripts/build_calendar.py
```

### 9f: Verify in Discord

Test by sending these messages in your #commands channel:
- "Search my inbox for unread emails from today"
- "What's on my calendar today?"
- "Create a calendar event: Test event tomorrow at 2pm to 3pm"

Claude calls exec → n8n → Gmail/Calendar API → returns formatted results.

### What SOUL.md teaches Claude to do

The SOUL.md file on the VPS already has the curl commands for Gmail and Calendar.
After workflows are deployed and active, Claude can use them immediately — no restart needed.

### Troubleshooting Gmail/Calendar

**"Workflow not found" or 404 from webhook:**
- Check workflow is Active (green toggle) in n8n Workflows list
- Verify webhook path: should be exactly `gmail-bridge` or `calendar-bridge`

**OAuth error / "invalid_client":**
- Confirm redirect URI in Google Cloud exactly matches: `http://100.94.99.89:5678/rest/oauth2-credential/callback`
- Note: http not https

**Empty results from Gmail search:**
- The Google account authorized must be the one with your email
- If you authorized a different account, delete the credential in n8n and re-create it

**n8n credential needs re-authorization (after ~6 months):**
- n8n → Credentials → find the Gmail or Calendar credential → click it → Reconnect
