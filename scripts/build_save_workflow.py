#!/usr/bin/env python3
"""Deploy the Research Save workflow to n8n."""
import json, requests, uuid

N8N_BASE = "http://100.94.99.89:5678"
N8N_API_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhZjhlZDNjMC1mZDAzLTQ0N2MtYjljNS1hMDQ4NmM3MTdlN2EiLCJpc3MiOiJuOG4iLCJhdWQiOiJwdWJsaWMtYXBpIiwiaWF0IjoxNzcyNDEyODMzfQ.vWDd6XX0hyJ-2ApLQfRZoZPBJCfZhU1RXyv5w94LcRA"
HEADERS = {"X-N8N-API-KEY": N8N_API_KEY, "Content-Type": "application/json"}
SSH_CRED = {"id": "atCi6uloSP2GsQoc", "name": "SSH Private Key account"}
WEBHOOK_DROPZONE = "https://discord.com/api/webhooks/1477831725164925184/4s8hdQRCsFWuJ3LbqwMi2Q9ZLgza2EjACBeS01UQzg2jxQAHZMaoo8nWF3wfWh8Cza1E"

def mk(name, type_, tv, pos, params, creds=None, cof=False):
    n = {"id": str(uuid.uuid4()), "name": name, "type": type_,
         "typeVersion": tv, "position": pos, "parameters": params}
    if creds: n["credentials"] = creds
    if cof:   n["continueOnFail"] = True
    return n

# 1. Webhook: research-save
webhook = mk("Webhook: research-save", "n8n-nodes-base.webhook", 2, [0, 0], {
    "httpMethod": "POST",
    "path": "research-save",
    "responseMode": "onReceived",
    "options": {}
})
webhook["webhookId"] = str(uuid.uuid4())

# 2. SSH: Check If Exists
# Uses inline n8n expression — no Buffer/btoa. grep -qF for fixed-string match.
ssh_check = mk("SSH: Check If Exists", "n8n-nodes-base.ssh", 1, [240, 0], {
    "resource": "command",
    "authentication": "privateKey",
    # IMPORTANT: SSH nodes require full ={{ }} expression — inline {{ }} is NOT evaluated.
    "command": "={{ \"grep -qF '\" + ($json.body.url || $json.url || '') + \"' ~/research-log.ndjson 2>/dev/null && echo duplicate || echo new\" }}"
}, {"sshPrivateKey": SSH_CRED}, cof=True)

# 3. Code: Parse + Route
code_parse = mk("Code: Parse Result", "n8n-nodes-base.code", 2, [480, 0], {
    "jsCode": """\
const stdout = ($input.first().json.stdout || '').trim();
const body = $('Webhook: research-save').first().json.body || $('Webhook: research-save').first().json;
const url = body.url || '';
return [{ json: { url, isNew: stdout !== 'duplicate', stdout } }];
"""
})

# 4. IF: Is New
if_new = mk("IF: Is New", "n8n-nodes-base.if", 2, [720, 0], {
    "conditions": {
        "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose"},
        "conditions": [{
            "id": str(uuid.uuid4()),
            "leftValue": "={{ $json.isNew }}",
            "rightValue": True,
            "operator": {"type": "boolean", "operation": "true"}
        }],
        "combinator": "and"
    }
})

# 5a. SSH: Save to Log (on true = new URL)
# Uses echo approach — avoids Buffer/btoa issues in n8n expression evaluator.
ssh_save = mk("SSH: Save to Log", "n8n-nodes-base.ssh", 1, [960, -150], {
    "resource": "command",
    "authentication": "privateKey",
    "command": (
        "={{ (function(){\n"
        "  const url = $json.url;\n"
        "  const entry = JSON.stringify({url: url, type: 'saved', title: url, score: null, summary: '', channel: 'saved', processed_at: new Date().toISOString(), saved: true});\n"
        "  const safe = entry.replace(/\\\\/g,'\\\\\\\\').replace(/\"/g,'\\\\\"').replace(/\\$/g,'\\\\$').replace(/`/g,'\\\\`');\n"
        "  return 'echo \"' + safe + '\" >> ~/research-log.ndjson && echo saved';\n"
        "})() }}"
    )
}, {"sshPrivateKey": SSH_CRED}, cof=True)

# 5b. HTTP: Discord Confirm (after SSH Save)
discord_confirm = mk("HTTP: Discord Confirm", "n8n-nodes-base.httpRequest", 4, [1200, -150], {
    "method": "POST",
    "url": WEBHOOK_DROPZONE,
    "sendBody": True,
    "specifyBody": "json",
    "jsonBody": "={{ JSON.stringify({content: '📌 Saved for later: ' + $('Code: Parse Result').first().json.url}) }}",
    "options": {}
}, cof=True)

# 6a. HTTP: Discord Already Saved (on false = already exists)
discord_exists = mk("HTTP: Discord Already Saved", "n8n-nodes-base.httpRequest", 4, [960, 150], {
    "method": "POST",
    "url": WEBHOOK_DROPZONE,
    "sendBody": True,
    "specifyBody": "json",
    "jsonBody": "={{ JSON.stringify({content: 'ℹ️ Already in reading list: ' + $json.url}) }}",
    "options": {}
}, cof=True)

# Connections
connections = {
    "Webhook: research-save": {"main": [[{"node": "SSH: Check If Exists", "type": "main", "index": 0}]]},
    "SSH: Check If Exists":   {"main": [[{"node": "Code: Parse Result", "type": "main", "index": 0}]]},
    "Code: Parse Result":     {"main": [[{"node": "IF: Is New", "type": "main", "index": 0}]]},
    "IF: Is New": {
        "main": [
            [{"node": "SSH: Save to Log", "type": "main", "index": 0}],   # true = new
            [{"node": "HTTP: Discord Already Saved", "type": "main", "index": 0}]  # false = exists
        ]
    },
    "SSH: Save to Log": {"main": [[{"node": "HTTP: Discord Confirm", "type": "main", "index": 0}]]},
}

workflow = {
    "name": "Research Save",
    "nodes": [webhook, ssh_check, code_parse, if_new, ssh_save, discord_confirm, discord_exists],
    "connections": connections,
    "settings": {"executionOrder": "v1"},
}

r = requests.post(f"{N8N_BASE}/api/v1/workflows", headers=HEADERS, json=workflow)
print(f"Create: {r.status_code}")
if r.status_code not in (200, 201):
    print(r.text[:2000])
    raise SystemExit(1)

new_id = r.json()["id"]
print(f"New workflow ID: {new_id}")

r2 = requests.post(f"{N8N_BASE}/api/v1/workflows/{new_id}/activate", headers=HEADERS)
print(f"Activate: {r2.status_code}")

print(f"\nWorkflow URL: {N8N_BASE}/workflow/{new_id}")
print(f"Webhook:     POST {N8N_BASE}/webhook/research-save")
print('Test: curl -X POST http://100.94.99.89:5678/webhook/research-save -H \'Content-Type: application/json\' -d \'{"url":"https://github.com/anthropics/anthropic-sdk-python"}\'')
