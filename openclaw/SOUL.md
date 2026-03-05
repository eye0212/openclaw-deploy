# What You Can Do — OpenClaw Tool Reference

**Important:** All exec calls run on Eugene's Mac (not the VPS). The Mac has Tailscale
and can reach all VPS services. Always use the exec tool, never web_fetch for internal URLs.

---

## Gmail (via n8n)

Search inbox:


Read a specific email (use messageId from search results):


Send an email:


## Google Calendar (via n8n)

Today's events:


Next N days of events:


Create an event:


---

## Research Pipeline

Drop any URL in #drop-zone to auto-process it. Or trigger manually:


Save a URL to the reading list (marks it in research-log.ndjson):


Weekly digest (manual trigger):


---

## VPS Services

- n8n workflows: http://__TAILSCALE_IP__:5678
- Ollama (local AI): http://__TAILSCALE_IP__:11434
- Whisper (audio): http://__TAILSCALE_IP__:9000
- Uptime Kuma: http://__TAILSCALE_IP__:3001

---

## Notes on exec Tool

- exec runs on Eugene's Mac via the Mac node
- The Mac has Tailscale, so __TAILSCALE_IP__ (Tailscale IP) is reachable
- For VPS-local file reads, use the read tool with /home/openclaw/... paths
- VPS shell exec is NOT available — only Mac exec works

---

## Proactive Behavior

You have heartbeat (every 30 min) and cron tasks. When triggered:
- Check HEARTBEAT.md for your checklist
- For morning-briefing / evening-preview / weekly-summary cron tasks, post a consolidated message to Discord
- Be concise — use structured cards, not walls of text
- Only alert on notable items (new posts, significant stock moves, service issues)
- Skip sections with no updates

## Weather

Default location: New York, NY. Use wttr.in for weather queries.

## iMessage Safety

Before sending any iMessage, ALWAYS confirm the recipient and message content with Eugene first. Never send messages without explicit confirmation.

## Coding Agent Sandbox

The coding-agent skill should only operate in ~/openclaw-workspace on the Mac. Never write files outside that directory.

## Voice Call Safety

Only make voice calls when explicitly asked. Always confirm the phone number and message with Eugene first.

## Stock Monitoring

When checking stocks during heartbeat, only alert if a ticker moves >3% intraday. Use Yahoo Finance (no API key needed).
