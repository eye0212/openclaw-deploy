#!/usr/bin/env python3
"""Build and deploy the Calendar Bridge workflow to n8n.

Creates a webhook at POST /webhook/calendar-bridge that queries or updates
Google Calendar based on the "action" field in the request body.

Actions:
  today   {"action":"today"}
  list    {"action":"list","days":7}
  create  {"action":"create","summary":"Meeting","start":"2026-03-10T10:00","end":"2026-03-10T11:00"}

Usage:
  N8N_API_KEY=xxx N8N_GCAL_CRED_ID=yyy python3 build_calendar.py
  python3 build_calendar.py --n8n-api-key xxx --gcal-cred-id yyy
"""
import json, requests, uuid, argparse, os, sys

# ── defaults from environment ─────────────────────────────────────────────────
_N8N_BASE      = os.environ.get("N8N_BASE_URL",       "http://100.94.99.89:5678")
_N8N_API_KEY   = os.environ.get("N8N_API_KEY",        "")
_GCAL_CRED_ID  = os.environ.get("N8N_GCAL_CRED_ID",  "")
_OLD_WF_ID     = os.environ.get("N8N_OLD_GCAL_WF_ID","")
_TIMEZONE      = os.environ.get("OPENCLAW_TIMEZONE",  "America/New_York")

parser = argparse.ArgumentParser(description="Deploy Calendar Bridge workflow to n8n")
parser.add_argument("--n8n-url",        default=_N8N_BASE)
parser.add_argument("--n8n-api-key",    default=_N8N_API_KEY)
parser.add_argument("--gcal-cred-id",   default=_GCAL_CRED_ID,
                    help="n8n credential ID for Google Calendar OAuth2 (create in n8n UI)")
parser.add_argument("--timezone",       default=_TIMEZONE,
                    help="Timezone for interpreting 'today' (default: America/New_York)")
parser.add_argument("--old-workflow-id",default=_OLD_WF_ID,
                    help="ID of existing Calendar Bridge workflow to replace")
args = parser.parse_args()

N8N_BASE   = args.n8n_url.rstrip("/")
HEADERS    = {"X-N8N-API-KEY": args.n8n_api_key, "Content-Type": "application/json"}
GCAL_CRED  = {"id": args.gcal_cred_id, "name": "Google Calendar OAuth2 API"}
TIMEZONE   = args.timezone

missing = []
if not args.n8n_api_key:  missing.append("n8n API key (--n8n-api-key or N8N_API_KEY)")
if not args.gcal_cred_id: missing.append("Google Calendar cred ID (--gcal-cred-id or N8N_GCAL_CRED_ID)")
if missing:
    print("ERROR — missing required arguments:")
    for m in missing: print(f"  • {m}")
    print("\nCreate the Google Calendar credential first:")
    print("  n8n UI → Credentials → New → Google Calendar OAuth2 API → connect Google account → copy credential ID")
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

def gcal(name, pos, op, params_extra):
    params = {
        "resource":  "event",
        "operation": op,
        "calendar":  {"mode": "list", "value": "primary"},
        **params_extra
    }
    return mk(name, "n8n-nodes-base.googleCalendar", pos, params,
              creds={"googleCalendarOAuth2Api": GCAL_CRED}, tv=1)

# ── nodes ─────────────────────────────────────────────────────────────────────
webhook_id = str(uuid.uuid4())
webhook = {
    "id":          str(uuid.uuid4()),
    "name":        "Calendar Bridge Webhook",
    "type":        "n8n-nodes-base.webhook",
    "typeVersion": 2,
    "position":    [0, 0],
    "webhookId":   webhook_id,
    "parameters": {
        "path":         "calendar-bridge",
        "httpMethod":   "POST",
        "responseMode": "lastNode",
        "options":      {}
    }
}

# Code: compute time ranges from action
compute_times = code("Compute Time Range", [240, 0], f"""
const body  = $input.first().json.body || {{}};
const action = body.action || 'today';
const tz = '{TIMEZONE}';

// Helper: start-of-day and end-of-day for a date offset from now
function dayRange(offsetDays) {{
  const now = new Date();
  const start = new Date(now);
  start.setUTCHours(0,0,0,0);
  start.setUTCDate(start.getUTCDate() + offsetDays);
  const end = new Date(start);
  end.setUTCDate(end.getUTCDate() + 1);
  return {{ start: start.toISOString(), end: end.toISOString() }};
}}

let timeMin, timeMax, maxResults = 50;

if (action === 'today') {{
  const r = dayRange(0);
  timeMin = r.start;
  timeMax = r.end;
  maxResults = 20;
}} else if (action === 'list') {{
  const days = parseInt(body.days) || 7;
  const r0 = dayRange(0);
  const rN = dayRange(days);
  timeMin = r0.start;
  timeMax = rN.end;
  maxResults = Math.min(days * 10, 100);
}} else {{
  // For 'create' or unknown actions, pass through
  timeMin = new Date().toISOString();
  timeMax = new Date(Date.now() + 86400000).toISOString();
}}

return [{{ json: {{
  action,
  timeMin,
  timeMax,
  maxResults,
  // Pass through create fields
  summary:  body.summary  || '',
  start:    body.start    || '',
  end:      body.end      || '',
  location: body.location || '',
  description: body.description || ''
}} }}];
""")

# Route: is it a create?
if_create = ifnode("IF: Create?", [480, 0],
                   "={{ $json.action }}", "create")

# Route: is it a list (multi-day)?
if_list = ifnode("IF: List?", [720, 120],
                 "={{ $json.action }}", "list")

# ── Calendar: Get events (today) ──────────────────────────────────────────────
cal_today = gcal("Calendar: Today", [960, 0], "getAll", {
    "returnAll":  False,
    "limit":      20,
    "options": {
        "timeMin":      "={{ $('Compute Time Range').first().json.timeMin }}",
        "timeMax":      "={{ $('Compute Time Range').first().json.timeMax }}",
        "orderBy":      "startTime",
        "singleEvents": True
    }
})

format_today = code("Format: Today", [1200, 0], r"""
const items = $input.all();
const events = items.map(item => {
  const e = item.json;
  const start = e.start?.dateTime || e.start?.date || '';
  const end   = e.end?.dateTime   || e.end?.date   || '';
  return {
    id:       e.id,
    summary:  e.summary   || '(no title)',
    start,
    end,
    location: e.location  || '',
    description: (e.description || '').slice(0, 200),
    allDay:   !e.start?.dateTime
  };
});
// Human-friendly time formatting
const formatted = events.map(e => {
  if (e.allDay) return `All day: ${e.summary}`;
  const s = new Date(e.start);
  const en = new Date(e.end);
  const fmt = d => d.toLocaleTimeString('en-US', {hour:'numeric', minute:'2-digit', hour12:true});
  return `${fmt(s)}–${fmt(en)}: ${e.summary}${e.location ? ' @ '+e.location : ''}`;
});
return [{ json: {
  action: 'today',
  count:  events.length,
  events,
  summary: events.length === 0
    ? 'No events today.'
    : 'Today:\n' + formatted.join('\n')
}}];
""")

# ── Calendar: Get events (list N days) ───────────────────────────────────────
cal_list = gcal("Calendar: List", [960, 240], "getAll", {
    "returnAll": False,
    "limit":     "={{ $('Compute Time Range').first().json.maxResults }}",
    "options": {
        "timeMin":      "={{ $('Compute Time Range').first().json.timeMin }}",
        "timeMax":      "={{ $('Compute Time Range').first().json.timeMax }}",
        "orderBy":      "startTime",
        "singleEvents": True
    }
})

format_list = code("Format: List", [1200, 240], r"""
const items = $input.all();
const events = items.map(item => {
  const e = item.json;
  const start = e.start?.dateTime || e.start?.date || '';
  const end   = e.end?.dateTime   || e.end?.date   || '';
  return {
    id:       e.id,
    summary:  e.summary || '(no title)',
    start, end,
    location: e.location || '',
    allDay:   !e.start?.dateTime
  };
});
// Group by date
const byDate = {};
events.forEach(e => {
  const day = e.start.slice(0, 10);
  if (!byDate[day]) byDate[day] = [];
  byDate[day].push(e);
});
const summaryLines = Object.entries(byDate).map(([date, evts]) => {
  const d = new Date(date + 'T12:00:00Z');
  const dayName = d.toLocaleDateString('en-US', {weekday:'short', month:'short', day:'numeric'});
  const eventLines = evts.map(e => {
    if (e.allDay) return `  • All day: ${e.summary}`;
    const s = new Date(e.start);
    const en = new Date(e.end);
    const fmt = d => d.toLocaleTimeString('en-US', {hour:'numeric', minute:'2-digit', hour12:true});
    return `  • ${fmt(s)}–${fmt(en)}: ${e.summary}`;
  });
  return dayName + '\n' + eventLines.join('\n');
});
return [{ json: {
  action: 'list',
  count:  events.length,
  events,
  summary: events.length === 0
    ? 'No events in the requested period.'
    : summaryLines.join('\n\n')
}}];
""")

# ── Calendar: Create event ────────────────────────────────────────────────────
cal_create = gcal("Calendar: Create", [720, -200], "create", {
    "summary":     "={{ $('Compute Time Range').first().json.summary }}",
    "start":       "={{ $('Compute Time Range').first().json.start }}",
    "end":         "={{ $('Compute Time Range').first().json.end }}",
    "additionalFields": {
        "location":    "={{ $('Compute Time Range').first().json.location }}",
        "description": "={{ $('Compute Time Range').first().json.description }}"
    }
})

format_create = code("Format: Create", [960, -200], r"""
const e = $input.first().json;
const start = e.start?.dateTime || e.start?.date || '';
return [{ json: {
  action:     'create',
  success:    true,
  eventId:    e.id,
  summary:    e.summary,
  start,
  end:        e.end?.dateTime || e.end?.date || '',
  htmlLink:   e.htmlLink || '',
  message:    `Event created: "${e.summary}" on ${start}`
}}];
""")

# ── assemble ──────────────────────────────────────────────────────────────────
all_nodes = [
    webhook, compute_times,
    if_create, if_list,
    cal_today, format_today,
    cal_list,  format_list,
    cal_create, format_create
]

connections = {
    "Calendar Bridge Webhook": {"main": [[
        {"node": "Compute Time Range", "type": "main", "index": 0}
    ]]},
    "Compute Time Range": {"main": [[
        {"node": "IF: Create?", "type": "main", "index": 0}
    ]]},
    "IF: Create?": {"main": [
        [{"node": "Calendar: Create", "type": "main", "index": 0}],   # true  → create
        [{"node": "IF: List?",        "type": "main", "index": 0}],   # false → check list
    ]},
    "IF: List?": {"main": [
        [{"node": "Calendar: List",   "type": "main", "index": 0}],   # true  → list N days
        [{"node": "Calendar: Today",  "type": "main", "index": 0}],   # false → today
    ]},
    "Calendar: Today":  {"main": [[{"node": "Format: Today",  "type": "main", "index": 0}]]},
    "Calendar: List":   {"main": [[{"node": "Format: List",   "type": "main", "index": 0}]]},
    "Calendar: Create": {"main": [[{"node": "Format: Create", "type": "main", "index": 0}]]},
}

workflow = {
    "name":        "Calendar Bridge",
    "nodes":       all_nodes,
    "connections": connections,
    "settings":    {"executionOrder": "v1"}
}

# ── deploy ────────────────────────────────────────────────────────────────────
print(f"Deploying Calendar Bridge to {N8N_BASE} ...")

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
Calendar Bridge deployed!
  Workflow ID : {new_id}
  Endpoint    : POST {N8N_BASE}/webhook/calendar-bridge
  Timezone    : {TIMEZONE}

Quick tests (after OAuth is connected):
  curl -X POST {N8N_BASE}/webhook/calendar-bridge \\
    -H 'Content-Type: application/json' -d '{{"action":"today"}}'

  curl -X POST {N8N_BASE}/webhook/calendar-bridge \\
    -H 'Content-Type: application/json' -d '{{"action":"list","days":7}}'

  curl -X POST {N8N_BASE}/webhook/calendar-bridge \\
    -H 'Content-Type: application/json' \\
    -d '{{"action":"create","summary":"Test event","start":"2026-03-10T10:00","end":"2026-03-10T11:00"}}'

Set N8N_OLD_GCAL_WF_ID={new_id} to replace this workflow next run.
""")
