#!/usr/bin/env python3
"""Build and deploy the Smart Research Intake Pipeline to n8n.

Usage (standalone):  python3 build_pipeline.py
Usage (from script): python3 build_pipeline.py --n8n-url URL --n8n-api-key KEY ...
"""
import json, requests, uuid, argparse, os, sys

# ── defaults from environment (no secrets hardcoded) ─────────────────────────
# Copy pipeline.env.example → pipeline.env, fill in values, then:
#   source pipeline.env && python3 build_pipeline.py
_N8N_BASE         = os.environ.get("N8N_BASE_URL", "http://localhost:5678")
_N8N_API_KEY      = os.environ.get("N8N_API_KEY", "")
_BRAVE_API_KEY    = os.environ.get("BRAVE_API_KEY", "")
_SSH_CRED         = {"id": os.environ.get("N8N_SSH_CRED_ID", ""), "name": "SSH Private Key account"}
_ANTH_CRED        = {"id": os.environ.get("N8N_ANTH_CRED_ID", ""), "name": "Anthropic account"}
_WEBHOOK_DROPZONE = os.environ.get("DISCORD_WEBHOOK_DROPZONE", "")
_WEBHOOK_PAPERS   = os.environ.get("DISCORD_WEBHOOK_PAPERS", "")
_WEBHOOK_PROJECTS = os.environ.get("DISCORD_WEBHOOK_PROJECTS", "")
OLD_WORKFLOW_ID   = os.environ.get("N8N_OLD_WORKFLOW_ID", "")

parser = argparse.ArgumentParser(description="Deploy Smart Research Intake Pipeline")
parser.add_argument("--n8n-url",          default=_N8N_BASE)
parser.add_argument("--n8n-api-key",      default=_N8N_API_KEY)
parser.add_argument("--brave-api-key",    default=_BRAVE_API_KEY)
parser.add_argument("--anthropic-cred-id",default=_ANTH_CRED["id"])
parser.add_argument("--ssh-cred-id",      default=_SSH_CRED["id"])
parser.add_argument("--webhook-dropzone", default=_WEBHOOK_DROPZONE)
parser.add_argument("--webhook-papers",   default=_WEBHOOK_PAPERS)
parser.add_argument("--webhook-projects", default=_WEBHOOK_PROJECTS)
args = parser.parse_args()

# Validate required secrets before doing anything
for label, val in [
    ("N8N_API_KEY / --n8n-api-key",           args.n8n_api_key),
    ("BRAVE_API_KEY / --brave-api-key",        args.brave_api_key),
    ("N8N_SSH_CRED_ID / --ssh-cred-id",        args.ssh_cred_id),
    ("N8N_ANTH_CRED_ID / --anthropic-cred-id", args.anthropic_cred_id),
    ("DISCORD_WEBHOOK_DROPZONE / --webhook-dropzone", args.webhook_dropzone),
    ("DISCORD_WEBHOOK_PAPERS / --webhook-papers",     args.webhook_papers),
    ("DISCORD_WEBHOOK_PROJECTS / --webhook-projects", args.webhook_projects),
]:
    if not val:
        print(f"ERROR: {label} is required. See scripts/pipeline.env.example.", file=sys.stderr)
        sys.exit(1)

N8N_BASE = args.n8n_url
HEADERS  = {"X-N8N-API-KEY": args.n8n_api_key, "Content-Type": "application/json"}
SSH_CRED  = {"id": args.ssh_cred_id,       "name": "SSH Private Key account"}
ANTH_CRED = {"id": args.anthropic_cred_id, "name": "Anthropic account"}
WEBHOOK_DROPZONE  = args.webhook_dropzone
WEBHOOK_PAPERS    = args.webhook_papers
WEBHOOK_PROJECTS  = args.webhook_projects

# ── helpers ──────────────────────────────────────────────────────────────────

def mk(name, type_, tv, pos, params, creds=None, continue_on_fail=False):
    n = {"id": str(uuid.uuid4()), "name": name, "type": type_,
         "typeVersion": tv, "position": pos, "parameters": params}
    if creds:
        n["credentials"] = creds
    if continue_on_fail:
        n["continueOnFail"] = True
    return n

def code(name, pos, js):
    return mk(name, "n8n-nodes-base.code", 2, pos, {"jsCode": js})

def http_get(name, pos, url_expr, text=False, never_error=True):
    opts = {}
    if text or never_error:
        resp = {}
        if text:
            resp["responseFormat"] = "text"
        if never_error:
            resp["neverError"] = True
        opts["response"] = {"response": resp}
    return mk(name, "n8n-nodes-base.httpRequest", 4, pos, {
        "url": url_expr, "options": opts
    }, continue_on_fail=True)

def claude_call(name, pos):
    return mk(name, "n8n-nodes-base.httpRequest", 4, pos, {
        "method": "POST",
        "url": "https://api.anthropic.com/v1/messages",
        "authentication": "predefinedCredentialType",
        "nodeCredentialType": "anthropicApi",
        "sendHeaders": True,
        "headerParameters": {"parameters": [
            {"name": "anthropic-version", "value": "2023-06-01"},
            {"name": "content-type",      "value": "application/json"},
        ]},
        "sendBody": True,
        "specifyBody": "json",
        "jsonBody": '={{ JSON.stringify({model: $json.model, max_tokens: $json.max_tokens, messages: $json.messages}) }}',
        "options": {}
    }, {"anthropicApi": ANTH_CRED}, continue_on_fail=True)

def discord_post(name, pos, webhook):
    # Only send content field — extra fields (title, score, etc.) would break Discord webhook
    return mk(name, "n8n-nodes-base.httpRequest", 4, pos, {
        "method": "POST", "url": webhook,
        "sendBody": True, "specifyBody": "json",
        "jsonBody": '={{ JSON.stringify({content: $json.content}) }}',
        "options": {}
    }, continue_on_fail=True)

def ssh_log(name, pos, format_card_node):
    """SSH node that appends a log entry to research-log.ndjson after successful pipeline run.

    Uses echo "..." >> file approach. JSON.stringify handles special chars.
    Shell-escapes: \\ → \\\\, " → \\", $ → \\$, ` → \\` for double-quoted string safety.
    continueOnFail=True so log failure never aborts the pipeline.
    """
    fc = format_card_node  # shorter alias for use in f-string below
    cmd = (
        "={{ (function(){\n"
        "  const fc = $('" + fc + "').first().json;\n"
        "  if (fc.isError) return 'echo skip-not-logged-error';\n"
        "  const url = $('URL Classifier').first().json.url;\n"
        "  const type_ = $('URL Classifier').first().json.type;\n"
        "  const entry = JSON.stringify({\n"
        "    url: url, type: type_,\n"
        "    title: String(fc.title||'').slice(0,200),\n"
        "    score: (fc.score !== undefined && fc.score !== null) ? Number(fc.score) : null,\n"
        "    summary: String(fc.summary||'').slice(0,200),\n"
        "    channel: fc.channel||'unknown',\n"
        "    processed_at: new Date().toISOString(), saved: false\n"
        "  });\n"
        "  const safe = entry.replace(/\\\\/g,'\\\\\\\\').replace(/\"/g,'\\\\\"').replace(/\\$/g,'\\\\$').replace(/`/g,'\\\\`');\n"
        "  return 'echo \"' + safe + '\" >> ~/research-log.ndjson && echo logged';\n"
        "})() }}"
    )
    return mk(name, "n8n-nodes-base.ssh", 1, pos, {
        "resource": "command",
        "authentication": "privateKey",
        "command": cmd
    }, {"sshPrivateKey": SSH_CRED}, continue_on_fail=True)

# ── nodes ────────────────────────────────────────────────────────────────────

# 1. Webhook
webhook = mk("Webhook", "n8n-nodes-base.webhook", 2, [0, 0], {
    "httpMethod": "POST",
    "path": "research-intake",
    "responseMode": "onReceived",
    "options": {}
})
webhook["webhookId"] = str(uuid.uuid4())

# 2. URL Classifier
classify = code("URL Classifier", [240, 0], """\
const raw = $input.first().json;
const url = (raw.body && raw.body.url ? raw.body.url : raw.url || '').trim();
const depth = (raw.body && raw.body._depth) ? parseInt(raw.body._depth) || 0 : 0;

let type = 'article';
if (url.includes('github.com/')) {
  const path = url.replace(/https?:\\/\\/github\\.com\\//, '').split('/');
  if (path.length >= 2 && path[0] && path[1]) type = 'github';
} else if (url.includes('arxiv.org/abs/') || url.includes('arxiv.org/pdf/')) {
  type = 'arxiv';
} else if (url.includes('youtube.com/watch') || url.includes('youtu.be/')) {
  type = 'youtube';
} else if (depth === 0) {
  // Only classify as social at depth 0 — resubmitted URLs skip this block
  if (url.includes('twitter.com/') || (url.includes('x.com/') && url.includes('/status/'))) {
    type = 'social';
  } else if (url.includes('bsky.app/profile/') && url.includes('/post/')) {
    type = 'social';
  } else if (url.includes('linkedin.com/posts/') || url.includes('linkedin.com/feed/updates/')) {
    type = 'social';
  } else if (url.includes('instagram.com/p/') || url.includes('instagram.com/reel/')) {
    type = 'social';
  }
}
return [{ json: { url, type, depth } }];
""")

# 3. SSH: Check Dup (NEW — deduplication check)
# Uses inline n8n expression {{ $json.url }} — no Buffer/btoa needed.
# grep -qF: fixed string, quiet (exit 0 if found, 1 if not).
# continueOnFail=True: if SSH fails, stdout is empty → IF evaluates as 'new' → proceed.
ssh_dedup = mk("SSH: Check Dup", "n8n-nodes-base.ssh", 1, [480, 0], {
    "resource": "command",
    "authentication": "privateKey",
    # IMPORTANT: SSH nodes require the full ={{ }} expression form — inline {{ }} is NOT evaluated.
    # Using string concatenation: grep for the literal URL in single quotes (safe for standard URLs).
    "command": "={{ \"grep -qF '\" + $json.url + \"' ~/research-log.ndjson 2>/dev/null && echo duplicate || echo new\" }}"
}, {"sshPrivateKey": SSH_CRED}, continue_on_fail=True)

# 4. IF: New URL (NEW — skip duplicates)
if_new = mk("IF: New URL", "n8n-nodes-base.if", 2, [720, 0], {
    "conditions": {
        "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose"},
        "conditions": [{
            "id": str(uuid.uuid4()),
            "leftValue": "={{ (($json.stdout || '').trim() === 'duplicate') ? 'duplicate' : 'new' }}",
            "rightValue": "new",
            "operator": {"type": "string", "operation": "equals", "name": "filter.operator.equals"}
        }],
        "combinator": "and"
    }
})

# 5. Switch (typeVersion 3 for n8n 2.x) — shifted right +480
# Switch must reference URL Classifier directly — after dedup nodes, $json is SSH output,
# not URL Classifier output. Using $('URL Classifier').first().json.type fixes routing.
def make_rule(field_val):
    return {
        "conditions": {
            "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose", "version": 2},
            "conditions": [{
                "id": str(uuid.uuid4()),
                "leftValue": "={{ $('URL Classifier').first().json.type }}",
                "rightValue": field_val,
                "operator": {"type": "string", "operation": "equals", "name": "filter.operator.equals"}
            }],
            "combinator": "and"
        },
        "renameOutput": False
    }

switch_node = mk("Switch", "n8n-nodes-base.switch", 3, [960, 0], {
    "mode": "rules",
    "rules": {"values": [
        make_rule("github"),
        make_rule("arxiv"),
        make_rule("youtube"),
        make_rule("social"),
    ]},
    "options": {"fallbackOutput": "extra"}
})

# ── Branch A: GitHub ── (all X positions shifted +480 from original) ──────────
Y = -900
gh_extract = code("GH: Extract Repo", [1200, Y], """\
const url = $('URL Classifier').first().json.url;
const clean = url.replace(/https?:\\/\\/github\\.com\\//, '');
const parts  = clean.split('/');
const owner  = parts[0];
const repo   = (parts[1] || '').split('?')[0].split('#')[0].replace(/\\.git$/, '');
if (!owner || !repo) throw new Error('Bad GitHub URL: ' + url);
return [{ json: { url, owner, repo, clone_url: 'https://github.com/' + owner + '/' + repo + '.git' } }];
""")

gh_api = mk("GH: GitHub API", "n8n-nodes-base.httpRequest", 4, [1440, Y], {
    "url": "={{ 'https://api.github.com/repos/' + $json.owner + '/' + $json.repo }}",
    "sendHeaders": True,
    "headerParameters": {"parameters": [
        {"name": "Accept",     "value": "application/vnd.github.v3+json"},
        {"name": "User-Agent", "value": "n8n-openclaw"},
    ]},
    "options": {}
}, continue_on_fail=True)

gh_readme = http_get("GH: Fetch README", [1680, Y],
    "={{ 'https://raw.githubusercontent.com/' + $('GH: Extract Repo').first().json.owner + '/' + $('GH: Extract Repo').first().json.repo + '/' + ($json.default_branch || 'main') + '/README.md' }}",
    text=True, never_error=True
)

gh_claude_build = code("GH: Build Claude Req", [1920, Y], """\
const gh    = $('GH: GitHub API').first().json;
const meta  = $('GH: Extract Repo').first().json;
const readme = ($input.first().json.data || $input.first().json.body || '').toString().substring(0, 3000);
const prompt = `Analyze this GitHub repo. Return ONLY valid JSON, no markdown fences.
Repo: ${meta.owner}/${meta.repo}
Description: ${gh.description || 'none'}
Language: ${gh.language || 'unknown'}
Topics: ${(gh.topics || []).join(', ')}
README:
${readme}

Return JSON:
{"summary":"2 sentences what it does","run_steps":["cmd1","cmd2"],"expose":"port:XXXX or null"}`;

return [{ json: {
  _meta: {
    owner: meta.owner,
    repo: meta.repo,
    clone_url: meta.clone_url,
    language: gh.language || 'Unknown',
    stars: gh.stargazers_count || 0,
    topics: gh.topics || [],
    description: gh.description || '',
    error: gh.message || (gh.id == null ? 'Repository not found or GitHub API error' : null),
  },
  model: 'claude-haiku-4-5-20251001',
  max_tokens: 500,
  messages: [{ role: 'user', content: prompt }]
}}];
""")

gh_claude = claude_call("GH: Call Claude", [2160, Y])

gh_ssh = mk("GH: SSH Clone+Run", "n8n-nodes-base.ssh", 1, [2400, Y], {
    "resource": "command",
    "authentication": "privateKey",
    "command": """\
={{ (function(){
  const meta = $('GH: Build Claude Req').first().json._meta;
  const repo = meta.repo;
  const cloneUrl = meta.clone_url;
  return `REPO_NAME=${repo}
CLONE_DIR=/home/openclaw/projects/$REPO_NAME
mkdir -p /home/openclaw/projects
if [ -d "$CLONE_DIR/.git" ]; then
  echo "Updating existing clone..."
  cd $CLONE_DIR && git pull --quiet 2>&1 | tail -2
else
  echo "Cloning..."
  git clone --depth 1 ${cloneUrl} $CLONE_DIR 2>&1 | tail -3
fi
cd $CLONE_DIR
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  echo "SETUP_TYPE:docker-compose"
  docker compose up -d 2>&1 | tail -5
  docker compose ps 2>&1 | head -8
elif [ -f requirements.txt ]; then
  echo "SETUP_TYPE:python"
  python3 -m venv .venv 2>/dev/null
  .venv/bin/pip install -r requirements.txt -q 2>&1 | tail -3
elif [ -f package.json ]; then
  echo "SETUP_TYPE:node"
  npm install --silent 2>&1 | tail -3
else
  echo "SETUP_TYPE:unknown"
fi
echo "DONE: $CLONE_DIR"`;
})() }}"""
}, {"sshPrivateKey": SSH_CRED}, continue_on_fail=True)

gh_format = code("GH: Format Card", [2640, Y], """\
const meta      = $('GH: Build Claude Req').first().json._meta;
const claudeRaw = $('GH: Call Claude').first().json;
const sshOut    = $input.first().json;
const url       = $('URL Classifier').first().json.url;

// Error detection
const hasError = meta.error || !claudeRaw.content;
if (hasError) {
  const errMsg = meta.error || 'Claude call failed';
  return [{ json: {
    content: `⚠️ **GitHub intake failed**\\n<${url}>\\nError: ${errMsg}\\nCheck n8n executions for details.`,
    title: url, score: null, summary: '', channel: 'drop-zone', isError: true
  }}];
}

let cd = {};
try {
  const txt = (claudeRaw.content || [])[0]?.text || '{}';
  cd = JSON.parse(txt.replace(/```json\\n?/g,'').replace(/```\\n?/g,'').trim());
} catch(e) { cd = { summary: 'See repo for details', run_steps: [], expose: null }; }

const steps   = (cd.run_steps || []).join('\\n');
const summary = cd.summary || meta.description || '';
const sshText = (sshOut.stdout || '').split('\\n').filter(l=>l.trim()).slice(-5).join('\\n');
const topics  = meta.topics.slice(0,4).map(t=>'`'+t+'`').join(' ');

let content = `🐙 **${meta.repo}** ★ ${meta.stars} · ${meta.language}\\n${summary}`;
if (steps)   content += `\\n\\n**To run:**\\n\\`\\`\\`\\n${steps}\\n\\`\\`\\``;
if (sshText) content += `\\n\\n**Setup:**\\n\\`\\`\\`\\n${sshText}\\n\\`\\`\\``;
content += `\\n📁 \\`/home/openclaw/projects/${meta.repo}\\``;
if (topics) content += `\\n${topics}`;

return [{ json: { content, title: meta.repo, score: null, summary: summary.slice(0, 200), channel: 'projects', isError: false } }];
""")

gh_discord = discord_post("GH: Post to Discord", [2880, Y], WEBHOOK_PROJECTS)
gh_log = ssh_log("GH: Log to File", [3120, Y], "GH: Format Card")

# ── Branch B: arxiv ── (all X positions shifted +480) ────────────────────────
Y = -350
ax_extract = code("AX: Extract ID", [1200, Y], """\
const url = $('URL Classifier').first().json.url;
const i = url.includes('/abs/') ? url.indexOf('/abs/')+5 : url.indexOf('/pdf/')+5;
const arxiv_id = url.substring(i).split('?')[0].split('#')[0];
if (!arxiv_id) throw new Error('Bad arxiv URL: ' + url);
return [{ json: { url, arxiv_id } }];
""")

ax_api = http_get("AX: arxiv API", [1440, Y],
    "={{ 'http://export.arxiv.org/api/query?id_list=' + $json.arxiv_id }}",
    text=True, never_error=True
)

ax_parse = code("AX: Parse XML", [1680, Y], """\
const arxiv_id = $('AX: Extract ID').first().json.arxiv_id;
const url      = $('AX: Extract ID').first().json.url;
const xml      = $input.first().json.data || $input.first().json.body || '';

function getTag(tag, str) {
  const m = str.match(new RegExp('<' + tag + '[^>]*>([\\\\s\\\\S]*?)<\\\\/' + tag + '>'));
  return m ? m[1].replace(/<[^>]+>/g,'').replace(/\\s+/g,' ').trim() : '';
}
const entry    = (xml.match(/<entry>([\\s\\S]*?)<\\/entry>/) || ['',''])[1];
const title    = getTag('title', entry) || 'Unknown Title';
const abstract = getTag('summary', entry) || '';
const published= (getTag('published', entry) || '').substring(0,10);
const authorMs = [...entry.matchAll(/<author>[^<]*<name>(.*?)<\\/name>/g)];
const authors  = authorMs.slice(0,3).map(m=>m[1].trim());

return [{ json: { arxiv_id, url, title, abstract, authors, published } }];
""")

ax_pwc = http_get("AX: Papers With Code", [1920, Y],
    "={{ 'https://paperswithcode.com/api/v1/papers/?arxiv_id=' + $json.arxiv_id }}",
    never_error=True
)

ax_claude_build = code("AX: Build Claude Req", [2160, Y], """\
const p   = $('AX: Parse XML').first().json;
const pwc = $input.first().json;

let githubUrl = null;
try {
  const r = pwc.results || [];
  if (r.length && r[0].repository) githubUrl = r[0].repository.url || null;
} catch(e) {}

const prompt = `Analyze this research paper. Return ONLY valid JSON, no markdown.
Title: ${p.title}
Authors: ${p.authors.join(', ')}
Published: ${p.published}
Abstract: ${p.abstract.substring(0,2000)}

Return JSON:
{"bullets":["bullet1 max 100 chars","bullet2","bullet3"],"score":7,"reason":"one sentence","tags":["keyword1","keyword2"]}`;

return [{ json: {
  _meta: { title: p.title, authors: p.authors, published: p.published,
           arxiv_id: p.arxiv_id, url: p.url, github_url: githubUrl },
  model: 'claude-haiku-4-5-20251001',
  max_tokens: 500,
  messages: [{ role: 'user', content: prompt }]
}}];
""")

ax_claude  = claude_call("AX: Call Claude",  [2400, Y])
ax_format  = code("AX: Format Card", [2640, Y], """\
const meta      = $('AX: Build Claude Req').first().json._meta;
const claudeRaw = $input.first().json;
const url       = $('URL Classifier').first().json.url;

// Error detection
const hasError = !meta.title || meta.title === 'Unknown Title' || !claudeRaw.content;
if (hasError) {
  return [{ json: {
    content: `⚠️ **arxiv intake failed**\\n<${url}>\\nCould not fetch paper or Claude failed. Check n8n executions.`,
    title: url, score: null, summary: '', channel: 'papers', isError: true
  }}];
}

let cd = {};
try {
  const txt = (claudeRaw.content || [])[0]?.text || '{}';
  cd = JSON.parse(txt.replace(/```json\\n?/g,'').replace(/```\\n?/g,'').trim());
} catch(e) { cd = { bullets:['Analysis failed'], score:0, reason:'', tags:[] }; }

const bullets  = (cd.bullets || []).map(b=>'• '+b).join('\\n');
const score    = cd.score || 0;
const reason   = cd.reason || '';
const tags     = (cd.tags || []).map(t=>'`'+t+'`').join(' ');
const codeLink = meta.github_url ? '🔗 Code: '+meta.github_url : '🔗 Code: not found';
const authors  = meta.authors.slice(0,2).join(', ') + (meta.authors.length>2 ? ' et al.' : '');

const content = `📄 **${meta.title}**\\n${authors} · ${meta.published}\\n\\n${bullets}\\n\\n🔥 **${score}/10** — ${reason}\\n${codeLink}\\n${tags}`;
return [{ json: { content, title: meta.title, score: cd.score || null, summary: (cd.bullets||[]).join(' ').slice(0, 200), channel: 'papers', isError: false } }];
""")
ax_discord = discord_post("AX: Post to Discord", [2880, Y], WEBHOOK_PAPERS)
ax_log = ssh_log("AX: Log to File", [3120, Y], "AX: Format Card")

# ── Branch C: YouTube ── (all X positions shifted +480) ──────────────────────
Y = 200
yt_extract = code("YT: Extract Video ID", [1200, Y], """\
const url = $('URL Classifier').first().json.url;
let vid = '';
if (url.includes('youtu.be/')) {
  vid = url.split('youtu.be/')[1].split('?')[0].split('#')[0];
} else if (url.includes('v=')) {
  vid = url.split('v=')[1].split('&')[0].split('#')[0];
}
if (!vid) throw new Error('Bad YouTube URL: ' + url);
return [{ json: { url, video_id: vid } }];
""")

yt_oembed = http_get("YT: oEmbed", [1440, Y],
    "={{ 'https://www.youtube.com/oembed?url=' + encodeURIComponent($json.url) + '&format=json' }}",
    never_error=True
)

yt_page = http_get("YT: Fetch Page", [1680, Y],
    "={{ $('YT: Extract Video ID').first().json.url }}",
    text=True, never_error=True
)

yt_claude_build = code("YT: Build Claude Req", [1920, Y], """\
const oe      = $('YT: oEmbed').first().json;
const pageRaw = $('YT: Fetch Page').first().json;
const vid     = $('YT: Extract Video ID').first().json;
const html    = pageRaw.data || pageRaw.body || '';
const title   = oe.title || 'Unknown Video';
const author  = oe.author_name || '';

const descM = html.match(/name=\\"description\\" content=\\"(.*?)\\"/);
const desc  = descM ? descM[1].replace(/\\\\n/g,'\\n').substring(0,1500) : '';

const prompt = `Summarize this YouTube video. Return ONLY valid JSON, no markdown.
Title: ${title}
Channel: ${author}
Description: ${desc}

Return JSON:
{"bullets":["bullet1","bullet2","bullet3"],"links":["github/arxiv URLs found if any"],"score":7,"reason":"one sentence"}`;

return [{ json: {
  _meta: { title, author, url: vid.url, video_id: vid.video_id, thumbnail: oe.thumbnail_url || '' },
  model: 'claude-haiku-4-5-20251001',
  max_tokens: 500,
  messages: [{ role: 'user', content: prompt }]
}}];
""")

yt_claude  = claude_call("YT: Call Claude",  [2160, Y])
yt_format  = code("YT: Format Card", [2400, Y], """\
const meta      = $('YT: Build Claude Req').first().json._meta;
const claudeRaw = $input.first().json;
const url       = $('URL Classifier').first().json.url;

// Error detection
const hasError = !meta.title || meta.title === 'Unknown Video' || !claudeRaw.content;
if (hasError) {
  return [{ json: {
    content: `⚠️ **YouTube intake failed**\\n<${url}>\\nVideo may be private or unavailable.`,
    title: url, score: null, summary: '', channel: 'drop-zone', isError: true
  }}];
}

let cd = {};
try {
  const txt = (claudeRaw.content || [])[0]?.text || '{}';
  cd = JSON.parse(txt.replace(/```json\\n?/g,'').replace(/```\\n?/g,'').trim());
} catch(e) { cd = { bullets:['See video'], score:0, reason:'', links:[] }; }

const bullets = (cd.bullets || []).map(b=>'• '+b).join('\\n');
const score   = cd.score || 0;
const reason  = cd.reason || '';
const links   = (cd.links || []).filter(l=>l && !l.includes('github/arxiv'));
const found   = links.length ? '\\n🔗 Found: '+links.join(' ') : '';

const content = `▶️ **${meta.title}**\\n${meta.author}\\n\\n${bullets}\\n\\n🔥 **${score}/10** — ${reason}${found}\\n${meta.url}`;
return [{ json: { content, title: meta.title, score: cd.score || null, summary: (cd.bullets||[]).join(' ').slice(0, 200), channel: 'drop-zone', isError: false } }];
""")
yt_discord = discord_post("YT: Post to Discord", [2640, Y], WEBHOOK_DROPZONE)
yt_log = ssh_log("YT: Log to File", [2880, Y], "YT: Format Card")

# ── Branch D: Article ── (all X positions shifted +480) ──────────────────────
Y = 750
ar_fetch = mk("AR: Fetch Page", "n8n-nodes-base.httpRequest", 4, [1200, Y], {
    "url": "={{ $('URL Classifier').first().json.url }}",
    "options": {
        "redirect": {"redirect": {"followRedirects": True, "maxRedirects": 5}},
        "response": {"response": {"responseFormat": "text", "neverError": True}},
        "timeout": 30000
    }
}, continue_on_fail=True)

ar_extract = code("AR: Extract Text", [1440, Y], """\
const url  = $('URL Classifier').first().json.url;
const html = $input.first().json.data || $input.first().json.body || '';
const text = html
  .replace(/<script[\\s\\S]*?<\\/script>/gi,'')
  .replace(/<style[\\s\\S]*?<\\/style>/gi,'')
  .replace(/<[^>]+>/g,' ')
  .replace(/&nbsp;/g,' ').replace(/&amp;/g,'&')
  .replace(/&lt;/g,'<').replace(/&gt;/g,'>')
  .replace(/&quot;/g,'"').replace(/&#39;/g,"'")
  .replace(/\\s+/g,' ').trim().substring(0, 6000);
return [{ json: { url, text } }];
""")

ar_claude_build = code("AR: Build Claude Req", [1680, Y], """\
const { url, text } = $input.first().json;
const prompt = `Analyze this web page. Return ONLY valid JSON, no markdown.
URL: ${url}
Content: ${text}

Return JSON:
{"title":"page title max 80 chars","bullets":["bullet1 max 120 chars","bullet2","bullet3"],"score":7,"reason":"one sentence","tags":["kw1","kw2"],"github_links":["any github repo URLs"],"arxiv_ids":["any arxiv IDs like 2408.09869"]}`;

return [{ json: {
  _meta: { url },
  model: 'claude-haiku-4-5-20251001',
  max_tokens: 600,
  messages: [{ role: 'user', content: prompt }]
}}];
""")

ar_claude  = claude_call("AR: Call Claude",  [1920, Y])
ar_format  = code("AR: Format Card", [2160, Y], """\
const meta      = $('AR: Build Claude Req').first().json._meta;
const claudeRaw = $input.first().json;
const url       = $('URL Classifier').first().json.url;

// Error detection
const hasError = !claudeRaw.content;
if (hasError) {
  return [{ json: {
    content: `⚠️ **Article intake failed**\\n<${url}>\\nCould not fetch page or Claude failed.`,
    title: url, score: null, summary: '', channel: 'drop-zone', isError: true
  }}];
}

let cd = {};
try {
  const txt = (claudeRaw.content || [])[0]?.text || '{}';
  cd = JSON.parse(txt.replace(/```json\\n?/g,'').replace(/```\\n?/g,'').trim());
} catch(e) { cd = { title: meta.url, bullets:['Content loaded'], score:0, reason:'', tags:[], github_links:[], arxiv_ids:[] }; }

const title   = cd.title || meta.url;
const bullets = (cd.bullets || []).map(b=>'• '+b).join('\\n');
const score   = cd.score || 0;
const reason  = cd.reason || '';
const tags    = (cd.tags || []).map(t=>'`'+t+'`').join(' ');
const ghLinks = cd.github_links || [];
const axIds   = cd.arxiv_ids || [];

let found = '';
if (ghLinks.length) found += '\\n🐙 Found: ' + ghLinks.join(' ');
if (axIds.length)   found += '\\n📄 Papers: ' + axIds.map(id=>'arxiv.org/abs/'+id).join(' ');

const content = `📰 **${title}**\\n${meta.url}\\n\\n${bullets}\\n\\n🔥 **${score}/10** — ${reason}${found}\\n${tags}`;
return [{ json: { content, title: title.slice(0, 100), score: cd.score || null, summary: (cd.bullets||[]).join(' ').slice(0, 200), channel: 'drop-zone', isError: false } }];
""")
ar_discord = discord_post("AR: Post to Discord", [2400, Y], WEBHOOK_DROPZONE)
ar_log = ssh_log("AR: Log to File", [2640, Y], "AR: Format Card")

# ── Branch E: Social ── Y=1300 ────────────────────────────────────────────────
Y = 1300
sm_fetch = http_get("SM: Fetch Post", [1200, Y],
    "={{ $('URL Classifier').first().json.url }}",
    text=True, never_error=True
)

# SSH node: calls ig_fetch.py for Instagram, returns {} for all other social URLs
_sm_ig_fetch_cmd = (
    "={{ (function(){\n"
    "  const url = $('URL Classifier').first().json.url;\n"
    "  if (!url.includes('instagram.com')) return 'echo \"{}\"';\n"
    "  const safe = url.replace(/\\\\/g,'\\\\\\\\').replace(/\"/g,'\\\\\"').replace(/\\$/g,'\\\\$').replace(/`/g,'\\\\`');\n"
    "  return 'PATH=$PATH:/home/openclaw/.local/bin python3 ~/scripts/ig_fetch.py \"' + safe + '\" 2>/dev/null || echo \"{}\"';\n"
    "})() }}"
)
sm_ig_fetch = mk("SM: IG Fetch", "n8n-nodes-base.ssh", 1, [1320, Y], {
    "resource": "command",
    "authentication": "privateKey",
    "command": _sm_ig_fetch_cmd
}, {"sshPrivateKey": SSH_CRED}, continue_on_fail=True)

sm_extract = code("SM: Extract + Build Req", [1440, Y], """\
const social_url = $('URL Classifier').first().json.url;
const html = $('SM: Fetch Post').first().json.data || $('SM: Fetch Post').first().json.body || '';

// Detect platform
let platform = 'social';
if (social_url.includes('twitter.com') || social_url.includes('x.com')) platform = 'Twitter/X';
else if (social_url.includes('instagram.com')) platform = 'Instagram';
else if (social_url.includes('bsky.app')) platform = 'Bluesky';
else if (social_url.includes('linkedin.com')) platform = 'LinkedIn';

// 0. IG caption from ig_fetch.py (Instagram only — highest priority)
let igFetchCaption = '';
try {
  const igData = JSON.parse($('SM: IG Fetch').first().json.stdout || '{}');
  igFetchCaption = igData.caption || '';
} catch(e) {}

// 1. OG tags
const ogTitleM = html.match(/<meta[^>]+property=[\\"']og:title[\\"'][^>]+content=[\\"'](.*?)[\\"']/i)
  || html.match(/<meta[^>]+content=[\\"'](.*?)[\\"'][^>]+property=[\\"']og:title[\\"']/i);
const ogDescM  = html.match(/<meta[^>]+property=[\\"']og:description[\\"'][^>]+content=[\\"'](.*?)[\\"']/i)
  || html.match(/<meta[^>]+content=[\\"'](.*?)[\\"'][^>]+property=[\\"']og:description[\\"']/i);
const ogTitle  = ogTitleM ? ogTitleM[1].replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&quot;/g,'"').replace(/&#39;/g,"'") : '';
const ogDesc   = ogDescM  ? ogDescM[1].replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&quot;/g,'"').replace(/&#39;/g,"'") : '';

// 2. Instagram caption from JSON-LD / script tags
let igCaption = '';
const capM = html.match(/"caption":\\s*"([^"]+)"/);
if (capM) igCaption = capM[1].replace(/\\\\n/g,'\\n').replace(/\\\\u00a9/gi,'©');

// 3. Body text fallback
const bodyText = html
  .replace(/<script[\\s\\S]*?<\\/script>/gi,'')
  .replace(/<style[\\s\\S]*?<\\/style>/gi,'')
  .replace(/<[^>]+>/g,' ')
  .replace(/&nbsp;/g,' ').replace(/&amp;/g,'&')
  .replace(/\\s+/g,' ').trim().substring(0, 2000);

const best = igFetchCaption || igCaption || (ogDesc.length > ogTitle.length ? ogDesc : ogTitle + ' ' + ogDesc) || bodyText;
const extracted_text = best.substring(0, 2000);

const prompt = `This is a ${platform} post (URL: ${social_url}).
Post content: ${extracted_text}

Identify what research paper, GitHub repo, or project this post is discussing.
Return ONLY valid JSON:
{
  "found_url": "https://..." or null,
  "found_type": "arxiv"|"github"|"article"|"none",
  "confidence": "high"|"medium"|"low"|"none",
  "search_query": "best web search to find the paper/repo if URL not found" or null,
  "reasoning": "one sentence"
}

Rules:
- found_url: ONLY if you can extract it from the post text directly (no hallucination)
- found_type "arxiv": specific arxiv paper; use https://arxiv.org/abs/XXXX.XXXXX format
- found_type "github": specific GitHub repo; use https://github.com/owner/repo format
- search_query: provide even if found_url is null — use paper title, authors, tool name, benchmark numbers — anything specific from the post. null only if post is completely vague.
- Do NOT guess found_url. It's okay to return null for found_url + a good search_query.`;

return [{ json: {
  model: 'claude-haiku-4-5-20251001',
  max_tokens: 300,
  messages: [{ role: 'user', content: prompt }],
  _platform: platform,
  _extracted_text: extracted_text,
} }];
""")

sm_claude_find = claude_call("SM: Call Claude Find", [1680, Y])

sm_parse_source = code("SM: Parse Source", [1920, Y], """\
const social_url = $('URL Classifier').first().json.url;
const claudeRaw = $input.first().json;
let cd = {};
try {
  const txt = (claudeRaw.content || [])[0]?.text || '{}';
  cd = JSON.parse(txt.replace(/```json\\n?/g,'').replace(/```\\n?/g,'').trim());
} catch(e) {}

// Validate found_url is not itself a social media URL (loop guard)
const socialDomains = ['twitter.com','x.com','bsky.app','instagram.com','linkedin.com'];
const foundUrlIsSocial = cd.found_url && socialDomains.some(d => cd.found_url.includes(d));

const hasDirectUrl = !!(cd.found_url &&
  !foundUrlIsSocial &&
  cd.found_type !== 'none' &&
  cd.confidence !== 'none');

return [{ json: {
  has_direct:   hasDirectUrl,
  found_url:    hasDirectUrl ? cd.found_url : null,
  found_type:   cd.found_type || 'none',
  confidence:   cd.confidence || 'none',
  search_query: cd.search_query || null,
  reasoning:    cd.reasoning || '',
  social_url,
} }];
""")

sm_if_direct = mk("IF: Has Direct URL", "n8n-nodes-base.if", 2, [2160, Y], {
    "conditions": {
        "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose"},
        "conditions": [{
            "id": str(uuid.uuid4()),
            "leftValue": "={{ $json.has_direct }}",
            "rightValue": True,
            "operator": {"type": "boolean", "operation": "equals", "name": "filter.operator.equals"}
        }],
        "combinator": "and"
    }
})

# Direct path (TRUE) — Y=1100
sm_resubmit_direct = mk("SM: Resubmit Direct", "n8n-nodes-base.httpRequest", 4, [2400, 1100], {
    "method": "POST",
    "url": f"{N8N_BASE}/webhook/research-intake",
    "sendBody": True,
    "specifyBody": "json",
    "jsonBody": '={{ JSON.stringify({url: $json.found_url, _depth: 1, _via: "social-direct", _confidence: $json.confidence}) }}',
    "options": {}
}, continue_on_fail=True)

sm_confirm_direct = mk("SM: Confirm Discord (D)", "n8n-nodes-base.httpRequest", 4, [2640, 1100], {
    "method": "POST",
    "url": WEBHOOK_DROPZONE,
    "sendBody": True,
    "specifyBody": "json",
    "jsonBody": ('={{ JSON.stringify({content: '
                 '"\\u{1F50D} Found " + $json.found_type + ": <" + $json.found_url + ">\\n"'
                 '+ "From: " + $json.social_url + "\\n"'
                 '+ $json.reasoning'
                 '+ ($json.confidence === "medium" ? " (matched from post text, please verify)" : "")'
                 '+ "\\nProcessing now — card will appear shortly."'
                 '}) }}'),
    "options": {}
}, continue_on_fail=True)

# Custom social log for direct path
_sm_log_d_cmd = (
    "={{ (function(){\n"
    "  const social_url = $('URL Classifier').first().json.url;\n"
    "  const found_url = $('SM: Parse Source').first().json.found_url || '';\n"
    "  const entry = JSON.stringify({\n"
    "    url: social_url, type: 'social',\n"
    "    title: String(social_url).slice(0,200),\n"
    "    score: null,\n"
    "    summary: String('-> ' + found_url).slice(0,200),\n"
    "    channel: 'drop-zone',\n"
    "    processed_at: new Date().toISOString(), saved: false\n"
    "  });\n"
    "  const safe = entry.replace(/\\\\/g,'\\\\\\\\').replace(/\"/g,'\\\\\"').replace(/\\$/g,'\\\\$').replace(/`/g,'\\\\`');\n"
    "  return 'echo \"' + safe + '\" >> ~/research-log.ndjson && echo logged';\n"
    "})() }}"
)
sm_log_direct = mk("SM: Log (D)", "n8n-nodes-base.ssh", 1, [2880, 1100], {
    "resource": "command",
    "authentication": "privateKey",
    "command": _sm_log_d_cmd
}, {"sshPrivateKey": SSH_CRED}, continue_on_fail=True)

# Search path (FALSE) — Y=1300
sm_brave = mk("SM: Brave Search", "n8n-nodes-base.httpRequest", 4, [2400, Y], {
    "url": "={{ 'https://api.search.brave.com/res/v1/web/search?q=' + encodeURIComponent($json.search_query || $json.social_url) + '&count=5' }}",
    "sendHeaders": True,
    "headerParameters": {"parameters": [
        {"name": "X-Subscription-Token", "value": args.brave_api_key},
        {"name": "Accept", "value": "application/json"},
    ]},
    "options": {"response": {"response": {"neverError": True}}}
}, continue_on_fail=True)

sm_build_rank = code("SM: Build Rank Req", [2640, Y], """\
const social_url = $('URL Classifier').first().json.url;
const search_query = $('SM: Parse Source').first().json.search_query;
const extracted_text = ($('SM: Extract + Build Req').first().json._extracted_text || '').trim();
const results = ($input.first().json.web || {}).results || [];

// Skip if no search_query and no content — login wall or totally empty post
const contentEmpty = !search_query && !extracted_text;
if (!results.length || contentEmpty) {
  return [{ json: {
    model: 'claude-haiku-4-5-20251001', max_tokens: 10,
    messages: [{role:'user', content:'Return exactly: {"found_url":null,"found_type":"none","confidence":"none"}'}],
    _rank_skip: true, social_url
  } }];
}

const items = results.slice(0, 5).map((r,i) =>
  `${i+1}. ${r.title}\\n   ${r.url}\\n   ${(r.description||'').slice(0,150)}`).join('\\n\\n');

const prompt = `You searched for: "${search_query}"
From a social media post at: ${social_url}

Search results:
${items}

Which result (if any) is the primary source — the actual paper, GitHub repo, or project the post is about?
Return ONLY valid JSON:
{"result_index": 1-5 or null, "found_url": "https://..." or null, "found_type": "arxiv"|"github"|"article"|"none", "confidence": "high"|"medium"|"low"}
- null if none of the results are clearly the source
- Prefer arxiv.org or github.com URLs`;

return [{ json: {
  _rank_skip: false,
  model: 'claude-haiku-4-5-20251001', max_tokens: 200,
  messages: [{role: 'user', content: prompt}],
  social_url,
} }];
""")

sm_claude_rank = claude_call("SM: Call Claude Rank", [2880, Y])

sm_parse_rank = code("SM: Parse Rank", [3120, Y], """\
const social_url = $('SM: Build Rank Req').first().json.social_url;
const search_query = $('SM: Parse Source').first().json.search_query;
const claudeRaw = $input.first().json;
let cd = {};
try {
  const txt = (claudeRaw.content || [])[0]?.text || '{}';
  cd = JSON.parse(txt.replace(/```json\\n?/g,'').replace(/```\\n?/g,'').trim());
} catch(e) {}

const socialDomains = ['twitter.com','x.com','bsky.app','instagram.com','linkedin.com'];
const isValid = !!(cd.found_url &&
  !socialDomains.some(d => cd.found_url.includes(d)) &&
  cd.confidence !== 'none' && cd.found_type !== 'none');

return [{ json: {
  rank_found:  isValid,
  found_url:   isValid ? cd.found_url : null,
  found_type:  cd.found_type || 'none',
  confidence:  cd.confidence || 'none',
  social_url,
  search_query,
} }];
""")

sm_if_rank = mk("IF: Rank Succeeded", "n8n-nodes-base.if", 2, [3360, Y], {
    "conditions": {
        "options": {"caseSensitive": True, "leftValue": "", "typeValidation": "loose"},
        "conditions": [{
            "id": str(uuid.uuid4()),
            "leftValue": "={{ $json.rank_found }}",
            "rightValue": True,
            "operator": {"type": "boolean", "operation": "equals", "name": "filter.operator.equals"}
        }],
        "combinator": "and"
    }
})

# Search found (TRUE) — Y=1100
sm_resubmit_search = mk("SM: Resubmit Search", "n8n-nodes-base.httpRequest", 4, [3600, 1100], {
    "method": "POST",
    "url": f"{N8N_BASE}/webhook/research-intake",
    "sendBody": True,
    "specifyBody": "json",
    "jsonBody": '={{ JSON.stringify({url: $json.found_url, _depth: 1, _via: "social-search", _confidence: $json.confidence}) }}',
    "options": {}
}, continue_on_fail=True)

sm_confirm_search = mk("SM: Confirm Discord (S)", "n8n-nodes-base.httpRequest", 4, [3840, 1100], {
    "method": "POST",
    "url": WEBHOOK_DROPZONE,
    "sendBody": True,
    "specifyBody": "json",
    "jsonBody": ('={{ JSON.stringify({content: '
                 '"\\u{1F50D} Found " + $json.found_type + " via search: <" + $json.found_url + ">\\n"'
                 '+ "Query: " + ($json.search_query||"") + "\\n"'
                 '+ "(search match — please verify)\\nProcessing now..."'
                 '}) }}'),
    "options": {}
}, continue_on_fail=True)

_sm_log_s_cmd = (
    "={{ (function(){\n"
    "  const social_url = $('URL Classifier').first().json.url;\n"
    "  const found_url = $('SM: Parse Rank').first().json.found_url || '';\n"
    "  const entry = JSON.stringify({\n"
    "    url: social_url, type: 'social',\n"
    "    title: String(social_url).slice(0,200),\n"
    "    score: null,\n"
    "    summary: String('-> ' + found_url + ' (search)').slice(0,200),\n"
    "    channel: 'drop-zone',\n"
    "    processed_at: new Date().toISOString(), saved: false\n"
    "  });\n"
    "  const safe = entry.replace(/\\\\/g,'\\\\\\\\').replace(/\"/g,'\\\\\"').replace(/\\$/g,'\\\\$').replace(/`/g,'\\\\`');\n"
    "  return 'echo \"' + safe + '\" >> ~/research-log.ndjson && echo logged';\n"
    "})() }}"
)
sm_log_search = mk("SM: Log (S)", "n8n-nodes-base.ssh", 1, [4080, 1100], {
    "resource": "command",
    "authentication": "privateKey",
    "command": _sm_log_s_cmd
}, {"sshPrivateKey": SSH_CRED}, continue_on_fail=True)

# Search not found (FALSE) — fallback summary — Y=1500
sm_build_summary = code("SM: Build Summary Req", [3600, 1500], """\
const social_url = $('URL Classifier').first().json.url;
const platform = $('SM: Extract + Build Req').first().json._platform || 'social';
const extracted_text = $('SM: Extract + Build Req').first().json._extracted_text || '';
const search_query = $('SM: Parse Rank').first().json.search_query || '';

const prompt = `Summarize this ${platform} post. Return ONLY valid JSON, no markdown.
URL: ${social_url}
Content: ${extracted_text}

Return JSON:
{"title":"short descriptive title max 80 chars","bullets":["bullet1 max 100 chars","bullet2","bullet3"],"score":5,"reason":"one sentence why this might be interesting"}`;

return [{ json: {
  _meta: { url: social_url, platform },
  model: 'claude-haiku-4-5-20251001',
  max_tokens: 400,
  messages: [{ role: 'user', content: prompt }],
} }];
""")

sm_claude_sum = claude_call("SM: Call Claude Sum", [3840, 1500])

sm_format_fallback = code("SM: Format Fallback", [4080, 1500], """\
const meta      = $('SM: Build Summary Req').first().json._meta;
const claudeRaw = $input.first().json;
const url       = $('URL Classifier').first().json.url;

let cd = {};
try {
  const txt = (claudeRaw.content || [])[0]?.text || '{}';
  cd = JSON.parse(txt.replace(/```json\\n?/g,'').replace(/```\\n?/g,'').trim());
} catch(e) { cd = { title: url, bullets:['Social post'], score:0, reason:'' }; }

const title   = cd.title || meta.platform + ' post';
const bullets = (cd.bullets || []).map(b=>'• '+b).join('\\n');
const score   = cd.score || 0;
const reason  = cd.reason || '';

const content = `\\u{1F4F2} **${title}**\\n${url}\\n\\n${bullets}\\n\\n\\u{1F525} **${score}/10** — ${reason}\\n(Source not identified — drop the direct URL if you find it)`;
return [{ json: {
  content,
  title: title.slice(0, 100),
  score: cd.score || null,
  summary: '(no source found)',
  channel: 'drop-zone',
  isError: false
} }];
""")

sm_post_fallback = discord_post("SM: Post Fallback", [4320, 1500], WEBHOOK_DROPZONE)
sm_log_fallback  = ssh_log("SM: Log Fallback", [4560, 1500], "SM: Format Fallback")

# ── YouTube upgrade: extract + resubmit sources ───────────────────────────────
yt_extract_sources = code("YT: Extract Sources", [2400, 350], """\
const claudeRaw = $input.first().json;
let cd = {};
try {
  const txt = (claudeRaw.content || [])[0]?.text || '{}';
  cd = JSON.parse(txt.replace(/```json\\n?/g,'').replace(/```\\n?/g,'').trim());
} catch(e) { cd = {}; }

const links = (cd.links || [])
  .filter(l => l && typeof l === 'string' && !l.includes('github/arxiv'))
  .filter(l => l.startsWith('https://') &&
    (l.includes('arxiv.org/abs/') || l.includes('arxiv.org/pdf/') || l.includes('github.com/')));

if (!links.length) return [];
return links.slice(0, 3).map(url => ({ json: { url } }));
""")

yt_resubmit_sources = mk("YT: Resubmit Sources", "n8n-nodes-base.httpRequest", 4, [2640, 350], {
    "method": "POST",
    "url": f"{N8N_BASE}/webhook/research-intake",
    "sendBody": True,
    "specifyBody": "json",
    "jsonBody": '={{ JSON.stringify({url: $json.url, _depth: 1, _via: "youtube"}) }}',
    "options": {}
}, continue_on_fail=True)

# ── connections ───────────────────────────────────────────────────────────────

connections = {}

def link(from_n, to_n, out=0):
    fn = from_n["name"]
    tn = to_n["name"]
    if fn not in connections:
        connections[fn] = {"main": []}
    while len(connections[fn]["main"]) <= out:
        connections[fn]["main"].append([])
    connections[fn]["main"][out].append({"node": tn, "type": "main", "index": 0})

# trunk: webhook → classify → dedup check → IF new → switch
link(webhook,   classify)
link(classify,  ssh_dedup)
link(ssh_dedup, if_new)
link(if_new,    switch_node, 0)   # output 0 = true = new URL
# output 1 (duplicate) intentionally unconnected

# switch → branches
link(switch_node, gh_extract, 0)
link(switch_node, ax_extract, 1)
link(switch_node, yt_extract, 2)
link(switch_node, sm_fetch,   3)
link(switch_node, ar_fetch,   4)

# GitHub chain (including new log node)
for a, b in [(gh_extract, gh_api), (gh_api, gh_readme), (gh_readme, gh_claude_build),
             (gh_claude_build, gh_claude), (gh_claude, gh_ssh),
             (gh_ssh, gh_format), (gh_format, gh_discord), (gh_discord, gh_log)]:
    link(a, b)

# arxiv chain
for a, b in [(ax_extract, ax_api), (ax_api, ax_parse), (ax_parse, ax_pwc),
             (ax_pwc, ax_claude_build), (ax_claude_build, ax_claude),
             (ax_claude, ax_format), (ax_format, ax_discord), (ax_discord, ax_log)]:
    link(a, b)

# YouTube chain
for a, b in [(yt_extract, yt_oembed), (yt_oembed, yt_page), (yt_page, yt_claude_build),
             (yt_claude_build, yt_claude), (yt_claude, yt_format),
             (yt_format, yt_discord), (yt_discord, yt_log)]:
    link(a, b)

# YouTube upgrade: fan-out from yt_claude into extract+resubmit
link(yt_claude, yt_extract_sources)
link(yt_extract_sources, yt_resubmit_sources)

# Social branch chain
for a, b in [(sm_fetch, sm_ig_fetch), (sm_ig_fetch, sm_extract), (sm_extract, sm_claude_find),
             (sm_claude_find, sm_parse_source), (sm_parse_source, sm_if_direct)]:
    link(a, b)
# Direct path (TRUE = output 0)
for a, b in [(sm_resubmit_direct, sm_confirm_direct), (sm_confirm_direct, sm_log_direct)]:
    link(a, b)
link(sm_if_direct, sm_resubmit_direct, 0)
# Search path (FALSE = output 1)
link(sm_if_direct, sm_brave, 1)
for a, b in [(sm_brave, sm_build_rank), (sm_build_rank, sm_claude_rank),
             (sm_claude_rank, sm_parse_rank), (sm_parse_rank, sm_if_rank)]:
    link(a, b)
# Rank succeeded (TRUE = output 0)
for a, b in [(sm_resubmit_search, sm_confirm_search), (sm_confirm_search, sm_log_search)]:
    link(a, b)
link(sm_if_rank, sm_resubmit_search, 0)
# Rank failed (FALSE = output 1) → fallback summary
link(sm_if_rank, sm_build_summary, 1)
for a, b in [(sm_build_summary, sm_claude_sum), (sm_claude_sum, sm_format_fallback),
             (sm_format_fallback, sm_post_fallback), (sm_post_fallback, sm_log_fallback)]:
    link(a, b)

# Article chain
for a, b in [(ar_fetch, ar_extract), (ar_extract, ar_claude_build),
             (ar_claude_build, ar_claude), (ar_claude, ar_format),
             (ar_format, ar_discord), (ar_discord, ar_log)]:
    link(a, b)

# ── build & deploy ────────────────────────────────────────────────────────────

all_nodes = [
    webhook, classify, ssh_dedup, if_new, switch_node,
    gh_extract, gh_api, gh_readme, gh_claude_build, gh_claude, gh_ssh, gh_format, gh_discord, gh_log,
    ax_extract, ax_api, ax_parse, ax_pwc, ax_claude_build, ax_claude, ax_format, ax_discord, ax_log,
    yt_extract, yt_oembed, yt_page, yt_claude_build, yt_claude, yt_format, yt_discord, yt_log,
    yt_extract_sources, yt_resubmit_sources,
    sm_fetch, sm_ig_fetch, sm_extract, sm_claude_find, sm_parse_source, sm_if_direct,
    sm_resubmit_direct, sm_confirm_direct, sm_log_direct,
    sm_brave, sm_build_rank, sm_claude_rank, sm_parse_rank, sm_if_rank,
    sm_resubmit_search, sm_confirm_search, sm_log_search,
    sm_build_summary, sm_claude_sum, sm_format_fallback, sm_post_fallback, sm_log_fallback,
    ar_fetch, ar_extract, ar_claude_build, ar_claude, ar_format, ar_discord, ar_log,
]

workflow = {
    "name": "Smart Research Intake",
    "nodes": all_nodes,
    "connections": connections,
    "settings": {"executionOrder": "v1"},
}

# Delete old workflow
r = requests.delete(f"{N8N_BASE}/api/v1/workflows/{OLD_WORKFLOW_ID}", headers=HEADERS)
print(f"Delete old ({OLD_WORKFLOW_ID}): {r.status_code}")

# Create new
r = requests.post(f"{N8N_BASE}/api/v1/workflows", headers=HEADERS, json=workflow)
print(f"Create: {r.status_code}")
if r.status_code not in (200, 201):
    print(r.text[:3000])
    raise SystemExit(1)

new_id = r.json()["id"]
print(f"New workflow ID: {new_id}")

# Activate
r2 = requests.post(f"{N8N_BASE}/api/v1/workflows/{new_id}/activate", headers=HEADERS)
print(f"Activate: {r2.status_code}")
if r2.status_code != 200:
    print(r2.text[:500])

print(f"\nWorkflow URL: {N8N_BASE}/workflow/{new_id}")
print(f"Webhook:     POST {N8N_BASE}/webhook/research-intake")
print(f"""Test commands:
  GitHub: curl -X POST {N8N_BASE}/webhook/research-intake -H 'Content-Type: application/json' -d '{{"url":"https://github.com/ollama/ollama"}}'
  arxiv:  curl -X POST {N8N_BASE}/webhook/research-intake -H 'Content-Type: application/json' -d '{{"url":"https://arxiv.org/abs/2408.09869"}}'
""")
