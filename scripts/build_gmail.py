#!/usr/bin/env python3
"""Build and deploy the Gmail Bridge workflow to n8n.

Creates a webhook at POST /webhook/gmail-bridge that routes to Gmail
based on the "action" field in the request body.

Actions:
  search  {"action":"search","query":"is:unread newer_than:1d"}
  read    {"action":"read","messageId":"<id>"}
  send    {"action":"send","to":"...","subject":"...","body":"..."}

Usage:
  N8N_API_KEY=xxx N8N_GMAIL_CRED_ID=yyy python3 build_gmail.py
  python3 build_gmail.py --n8n-api-key xxx --gmail-cred-id yyy
"""
import json, requests, uuid, argparse, os, sys

# ── defaults from environment ─────────────────────────────────────────────────
_N8N_BASE        = os.environ.get("N8N_BASE_URL",         "http://localhost:5678")
_N8N_API_KEY     = os.environ.get("N8N_API_KEY",          "")
_GMAIL_CRED_ID   = os.environ.get("N8N_GMAIL_CRED_ID",   "")
_OLD_WF_ID       = os.environ.get("N8N_OLD_GMAIL_WF_ID", "")

parser = argparse.ArgumentParser(description="Deploy Gmail Bridge workflow to n8n")
parser.add_argument("--n8n-url",        default=_N8N_BASE)
parser.add_argument("--n8n-api-key",    default=_N8N_API_KEY)
parser.add_argument("--gmail-cred-id",  default=_GMAIL_CRED_ID,
                    help="n8n credential ID for Gmail OAuth2 (create in n8n UI → Credentials → Gmail OAuth2)")
parser.add_argument("--old-workflow-id",default=_OLD_WF_ID,
                    help="ID of existing Gmail Bridge workflow to replace")
args = parser.parse_args()

N8N_BASE   = args.n8n_url.rstrip("/")
HEADERS    = {"X-N8N-API-KEY": args.n8n_api_key, "Content-Type": "application/json"}
GMAIL_CRED = {"id": args.gmail_cred_id, "name": "Gmail OAuth2"}

missing = []
if not args.n8n_api_key:   missing.append("n8n API key  (--n8n-api-key or N8N_API_KEY)")
if not args.gmail_cred_id: missing.append("Gmail cred ID (--gmail-cred-id or N8N_GMAIL_CRED_ID)")
if missing:
    print("ERROR — missing required arguments:")
    for m in missing: print(f"  • {m}")
    print("\nCreate the Gmail credential first:")
    print("  n8n UI → Credentials → New → Gmail OAuth2 → connect Google account → copy the credential ID")
    sys.exit(1)

# ── node helpers ──────────────────────────────────────────────────────────────
def mk(name, type_, pos, params, creds=None, tv=1, *, fail=True):
    n = {"id": str(uuid.uuid4()), "name": name, "type": type_,
         "typeVersion": tv, "position": list(pos), "parameters": params}
    if creds: n["credentials"] = creds
    if fail:  n["onError"] = "continueRegularOutput"
    return n

def code(name, pos, js):
    return mk(name, "n8n-nodes-base.code", pos, {"jsCode": js}, tv=2)

def ifnode(name, pos, left, right):
    return mk(name, "n8n-nodes-base.if", pos, {
        "conditions": {
            "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "strict"},
            "conditions": [{
                "id": str(uuid.uuid4()),
                "leftValue": left,
                "rightValue": right,
                "operator": {"type": "string", "operation": "equals",
                             "name": "filter.operator.equals"}
            }],
            "combinator": "and"
        }
    }, tv=2, fail=False)

def gmail(name, pos, op, params_extra):
    params = {"resource": "message", "operation": op, **params_extra}
    return mk(name, "n8n-nodes-base.gmail", pos, params,
              creds={"gmailOAuth2": GMAIL_CRED}, tv=2)

# ── nodes ─────────────────────────────────────────────────────────────────────
webhook_id = str(uuid.uuid4())
webhook = {
    "id":          str(uuid.uuid4()),
    "name":        "Gmail Bridge Webhook",
    "type":        "n8n-nodes-base.webhook",
    "typeVersion": 2,
    "position":    [0, 0],
    "webhookId":   webhook_id,
    "parameters": {
        "path":         "gmail-bridge",
        "httpMethod":   "POST",
        "responseMode": "lastNode",
        "options":      {}
    }
}

# Route: is it a search?
if_search = ifnode("IF: Search?", [240, 0],
                   "={{ $json.body.action }}", "search")

# Route: is it a read?
if_read = ifnode("IF: Read?", [480, 120],
                 "={{ $json.body.action }}", "read")

# ── Gmail: Search ─────────────────────────────────────────────────────────────
gmail_search = gmail("Gmail: Search", [720, -120], "getAll", {
    "returnAll": False,
    "limit": 10,
    "filters": {
        "q": "={{ $('Gmail Bridge Webhook').first().json.body.query || 'is:unread' }}"
    }
})

format_search = code("Format: Search", [960, -120], r"""
const items = $input.all();
const messages = items.map(item => {
  const msg = item.json;
  const headers = msg.payload?.headers || [];
  const h = name => headers.find(hdr => hdr.name === name)?.value || '';
  return {
    id:       msg.id,
    threadId: msg.threadId,
    from:     h('From'),
    subject:  h('Subject') || '(no subject)',
    date:     h('Date'),
    snippet:  msg.snippet || '',
    unread:   (msg.labelIds || []).includes('UNREAD')
  };
});
return [{ json: { action: 'search', count: messages.length, messages } }];
""")

# ── Gmail: Get (read full message) ───────────────────────────────────────────
gmail_get = gmail("Gmail: Get", [720, 120], "get", {
    "messageId": "={{ $('Gmail Bridge Webhook').first().json.body.messageId }}",
    "options":   {}
})

format_get = code("Format: Get", [960, 120], r"""
const msg = $input.first().json;
const headers = msg.payload?.headers || [];
const h = name => headers.find(hdr => hdr.name === name)?.value || '';

// Recursively extract plain-text body from MIME parts
function extractText(payload) {
  if (!payload) return '';
  if (payload.body?.data) {
    try { return Buffer.from(payload.body.data, 'base64').toString('utf-8'); }
    catch { return ''; }
  }
  if (payload.parts) {
    // prefer text/plain
    for (const p of payload.parts) {
      if (p.mimeType === 'text/plain') return extractText(p);
    }
    // fallback to any part
    for (const p of payload.parts) {
      const t = extractText(p);
      if (t) return t;
    }
  }
  return '';
}

const body = extractText(msg.payload).slice(0, 4000);
return [{ json: {
  action:   'read',
  id:       msg.id,
  threadId: msg.threadId,
  from:     h('From'),
  to:       h('To'),
  subject:  h('Subject') || '(no subject)',
  date:     h('Date'),
  snippet:  msg.snippet || '',
  body,
  truncated: extractText(msg.payload).length > 4000
}}];
""")

# ── Gmail: Send ───────────────────────────────────────────────────────────────
gmail_send = gmail("Gmail: Send", [720, 360], "send", {
    "sendTo":      "={{ $('Gmail Bridge Webhook').first().json.body.to }}",
    "subject":     "={{ $('Gmail Bridge Webhook').first().json.body.subject }}",
    "message":     "={{ $('Gmail Bridge Webhook').first().json.body.body }}",
    "contentType": "text",
    "options":     {}
})

format_send = code("Format: Send", [960, 360], r"""
const result = $input.first().json;
return [{ json: {
  action:    'send',
  success:   true,
  messageId: result.id || '',
  message:   'Email sent successfully'
}}];
""")

# Error fallback for unknown action
code_unknown = code("Unknown Action", [480, -160], r"""
const action = $input.first().json.body?.action || '(none)';
return [{ json: {
  error: 'Unknown action: ' + action,
  validActions: ['search', 'read', 'send']
}}];
""")

# ── assemble ──────────────────────────────────────────────────────────────────
all_nodes = [
    webhook,
    if_search, if_read,
    gmail_search, format_search,
    gmail_get,   format_get,
    gmail_send,  format_send,
    code_unknown
]

connections = {
    "Gmail Bridge Webhook": {"main": [[
        {"node": "IF: Search?", "type": "main", "index": 0}
    ]]},
    "IF: Search?": {"main": [
        [{"node": "Gmail: Search",    "type": "main", "index": 0}],  # true  → search
        [{"node": "IF: Read?",        "type": "main", "index": 0}],  # false → check read
    ]},
    "IF: Read?": {"main": [
        [{"node": "Gmail: Get",       "type": "main", "index": 0}],  # true  → read
        [{"node": "Gmail: Send",      "type": "main", "index": 0}],  # false → send
    ]},
    "Gmail: Search": {"main": [[{"node": "Format: Search", "type": "main", "index": 0}]]},
    "Gmail: Get":    {"main": [[{"node": "Format: Get",    "type": "main", "index": 0}]]},
    "Gmail: Send":   {"main": [[{"node": "Format: Send",   "type": "main", "index": 0}]]},
}

workflow = {
    "name":        "Gmail Bridge",
    "nodes":       all_nodes,
    "connections": connections,
    "settings":    {"executionOrder": "v1"}
}

# ── deploy ────────────────────────────────────────────────────────────────────
print(f"Deploying Gmail Bridge to {N8N_BASE} ...")

if args.old_workflow_id:
    r = requests.delete(f"{N8N_BASE}/api/v1/workflows/{args.old_workflow_id}",
                        headers=HEADERS)
    print(f"  Deleted old workflow {args.old_workflow_id}: HTTP {r.status_code}")

r = requests.post(f"{N8N_BASE}/api/v1/workflows", headers=HEADERS, json=workflow)
if not r.ok:
    print(f"ERROR creating workflow: {r.status_code}")
    print(r.text[:500])
    sys.exit(1)

new_id = r.json()["id"]
print(f"  Created workflow: {new_id}")

r = requests.post(f"{N8N_BASE}/api/v1/workflows/{new_id}/activate", headers=HEADERS)
if r.ok:
    print(f"  Activated ✓")
else:
    print(f"  WARNING: activation failed ({r.status_code}) — activate manually in n8n UI")

print(f"""
Gmail Bridge deployed!
  Workflow ID : {new_id}
  Endpoint    : POST {N8N_BASE}/webhook/gmail-bridge

Quick test (after OAuth is connected):
  curl -X POST {N8N_BASE}/webhook/gmail-bridge \\
    -H 'Content-Type: application/json' \\
    -d '{{"action":"search","query":"is:unread newer_than:1d"}}'

Set N8N_OLD_GMAIL_WF_ID={new_id} to replace this workflow next run.
""")
