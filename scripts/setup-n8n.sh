#!/usr/bin/env bash
# setup-n8n.sh — Post-deployment n8n pipeline setup
# Run as: bash ~/openclaw-deploy/scripts/setup-n8n.sh (after n8n account is created)
# Required env vars: N8N_API_KEY, ANTHROPIC_API_KEY, WEBHOOK_DROPZONE, WEBHOOK_PAPERS, WEBHOOK_PROJECTS

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# 1. Check required vars
[[ -z "$N8N_API_KEY" ]] && error "N8N_API_KEY is required"
[[ -z "$ANTHROPIC_API_KEY" ]] && error "ANTHROPIC_API_KEY is required"
[[ -z "$WEBHOOK_DROPZONE" ]] && error "WEBHOOK_DROPZONE is required"
[[ -z "$WEBHOOK_PAPERS" ]] && error "WEBHOOK_PAPERS is required"
[[ -z "$WEBHOOK_PROJECTS" ]] && error "WEBHOOK_PROJECTS is required"

N8N_URL="http://$(grep '^TAILSCALE_IP=' ~/compose/.env | cut -d= -f2):5678"

# 2. Check n8n reachable
curl -sf "$N8N_URL/healthz" -o /dev/null || error "n8n not reachable at $N8N_URL — is it running?"
info "n8n reachable at $N8N_URL"

# 3. Create Anthropic credential
info "Creating Anthropic credential..."
ANTH_RESP=$(curl -sf -X POST "$N8N_URL/api/v1/credentials" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"Anthropic account\",\"type\":\"anthropicApi\",\"data\":{\"apiKey\":\"$ANTHROPIC_API_KEY\"}}")
ANTH_CRED_ID=$(echo "$ANTH_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
[[ -z "$ANTH_CRED_ID" ]] && error "Failed to create Anthropic credential: $ANTH_RESP"
info "Anthropic credential created: $ANTH_CRED_ID"

# 4. Generate RSA PEM SSH key for n8n
info "Generating SSH key for n8n..."
ssh-keygen -t rsa -b 4096 -m PEM -f ~/.ssh/n8n_key -N "" -q 2>/dev/null || true
KEY_PUB=$(cat ~/.ssh/n8n_key.pub | awk '{print $2}')
grep -qF "$KEY_PUB" ~/.ssh/authorized_keys 2>/dev/null || \
  cat ~/.ssh/n8n_key.pub >> ~/.ssh/authorized_keys
info "SSH key configured in authorized_keys"

# 5. Create SSH credential in n8n
TAILSCALE_IP=$(grep '^TAILSCALE_IP=' ~/compose/.env | cut -d= -f2)
SSH_PORT=$(grep '^SSH_PORT=' ~/compose/.env | cut -d= -f2 2>/dev/null || echo 2222)
SSH_RESP=$(curl -sf -X POST "$N8N_URL/api/v1/credentials" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "import json; print(json.dumps({'name':'SSH Private Key account','type':'sshPrivateKey','data':{'host':'$TAILSCALE_IP','port':int('$SSH_PORT'),'username':'openclaw','privateKey':open('/home/openclaw/.ssh/n8n_key').read()}}))")")
SSH_CRED_ID=$(echo "$SSH_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
[[ -z "$SSH_CRED_ID" ]] && error "Failed to create SSH credential: $SSH_RESP"
info "SSH credential created: $SSH_CRED_ID"

# 6. Deploy research pipeline
info "Deploying Smart Research Intake pipeline..."
python3 ~/openclaw-deploy/scripts/build_pipeline.py \
  --n8n-url "$N8N_URL" \
  --n8n-api-key "$N8N_API_KEY" \
  --anthropic-cred-id "$ANTH_CRED_ID" \
  --ssh-cred-id "$SSH_CRED_ID" \
  --webhook-dropzone "$WEBHOOK_DROPZONE" \
  --webhook-papers "$WEBHOOK_PAPERS" \
  --webhook-projects "$WEBHOOK_PROJECTS"
info "Pipeline deployed"

# 7. Update drop-zone systemPrompt in openclaw.json
info "Configuring drop-zone auto-trigger..."
VPS_N8N_IP=$(grep '^TAILSCALE_IP=' ~/compose/.env | cut -d= -f2)
python3 << PYEOF
import json
cfg_path = '/home/openclaw/.openclaw/openclaw.json'
with open(cfg_path) as f: cfg = json.load(f)
new_prompt = (
    'You are the research intake bot for the #drop-zone channel. '
    'When a message contains a URL (starting with http:// or https://), your ONLY job is:\n'
    '1. Extract the URL from the message\n'
    '2. Use the exec tool to run this EXACT command (replace THE_URL with the actual URL):\n'
    '   curl -s -X POST \'http://${VPS_N8N_IP}:5678/webhook/research-intake\' '
    '-H \'Content-Type: application/json\' -d \'{"url":"THE_URL"}\'\n'
    '3. Respond with: "Processing THE_URL... card will appear shortly \u2713"\n\n'
    'IMPORTANT: Use exec tool, NOT web_fetch. exec runs on Mac which can reach VPS.\n'
    'If message contains no URL, respond normally.'
)
for gid, guild in cfg['channels']['discord']['guilds'].items():
    if 'drop-zone' in guild.get('channels', {}):
        guild['channels']['drop-zone']['systemPrompt'] = new_prompt
with open(cfg_path, 'w') as f: json.dump(cfg, f, indent=2)
print('openclaw.json updated')
PYEOF

# 8. Restart gateway
systemctl --user restart openclaw-gateway.service
sleep 3
info "Gateway restarted"

# 9. Smoke test
info "Running smoke test..."
TEST_RESULT=$(curl -s -X POST "$N8N_URL/webhook/research-intake" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://arxiv.org/abs/2408.09869"}')
if echo "$TEST_RESULT" | grep -q "Workflow was started"; then
  info "Smoke test PASSED — pipeline is accepting requests"
else
  warn "Smoke test returned unexpected: $TEST_RESULT"
fi

echo ""
echo "════════════════════════════════════════════════"
echo "  Research pipeline setup complete!"
echo "  Drop a URL in Discord #drop-zone to test."
echo "════════════════════════════════════════════════"
