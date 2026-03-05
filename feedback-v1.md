# OpenClaw Deployment Feedback — v1

Session: Eugene's first deployment, 2026-02-28.
Time from start to working services: ~3 hours (should be ~30 minutes).
Bugs hit: 12. Manual recovery steps required: 3.

---

## SECTION 1: Script Bugs (Breaking Failures)

---

### Bug 1 — SSH key path tilde not expanded

**Where:** CLAUDE.md Step 2 → `deploy.sh` invocation example
**What happened:** CLAUDE.md example uses `OPENCLAW_SSH_KEY="~/.ssh/id_ed25519"`. The `~` is not shell-expanded when passed as a quoted env var — deploy.sh sees the literal string `~/.ssh/id_ed25519` and reports "SSH key not found."
**Fix:** `deploy.sh` should expand tilde itself: `SSH_KEY="${OPENCLAW_SSH_KEY/#\~/$HOME}"`. Also fix the CLAUDE.md example to use `$HOME/.ssh/id_ed25519`.

---

### Bug 2 — `age` v1.3.1 missing `checksums.txt` → full abort

**Where:** `setup-root.sh` Step 2d
**What happened:** Script fetches latest age version via GitHub API (v1.3.1), then downloads `checksums.txt` from the release. That file doesn't exist for v1.3.1. `curl -fsSL` returns exit code 22 (HTTP 404). With `set -e`, the entire script aborts — before user creation, SSH hardening, or Tailscale.
**Fix applied:** Graceful fallback — skip checksum verification with a warning if the file isn't found.
**Better fix:** Inspect the GitHub release JSON to find the actual checksum asset name dynamically, rather than assuming a filename. Or pin age to a specific version known to have checksums.

---

### Bug 3 — `sops` sha256 file missing for latest release (same pattern)

**Where:** `setup-root.sh` Step 2e
**What happened:** sops v3.12.1 doesn't have a `.sha256` file at the expected URL. Same abort as bug #2.
**Fix applied:** Same graceful fallback.

---

### Bug 4 — Docker Compose plugin sha256 missing (same pattern again)

**Where:** `setup-user.sh` Step 2
**What happened:** Third occurrence of the same pattern — latest docker/compose release missing `.sha256`. Also: `docker compose` was already installed via the system package (`docker-compose-plugin`), so the whole download was unnecessary.
**Fix applied:** Check `docker compose version` first; skip download entirely if it works. Added same checksum fallback.
**Root cause of pattern:** All three tools (age, sops, docker compose) use GitHub releases with inconsistent checksum file naming across versions. The scripts assume a fixed filename and hard-fail if it's missing. This needs a systemic fix — either dynamically discover checksum asset names from the release JSON, or gracefully skip when absent.

---

### Bug 5 — Wrong SSH service name → **SERVER LOCKOUT** ⚠️

**Where:** `setup-root.sh` Step 7 — SSH restart
**What happened:** Script runs `systemctl restart sshd.service`. On Ubuntu 24.04, the service is `ssh.service` not `sshd.service`. The restart fails (exit code 5). By this point UFW was already enabled with default-deny and only port 2222 open. The SSH daemon never restarted, so it kept listening on port 22 — which UFW now blocked. Port 2222 was also unreachable (config written but daemon not reloaded). Complete lockout.
**Recovery required:** Hetzner rescue system + editing UFW config file in chroot + reboot.
**Fix:** Use `systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null` to handle both Ubuntu versions. More importantly: restart SSH *before* enabling UFW, not after. If SSH restart fails, abort and do NOT enable UFW.

---

### Bug 6 — UFW enabled before SSH confirmed on new port (root cause of lockout)

**Where:** `setup-root.sh` Steps 6–7 ordering
**What happened:** The order was: (1) write SSH config, (2) configure UFW rules, (3) enable UFW, (4) restart SSH. Step 4 failing after step 3 = lockout. The loopback SSH self-test in step 7 was inconclusive and only warned — it didn't prevent UFW from being enabled.
**Fix:** Reorder: (1) restart SSH service, (2) verify SSH is listening on new port, (3) only then enable UFW. If the verification fails, abort without touching UFW. The current "warn and continue" behavior is dangerous.

---

### Bug 7 — `docker-ce` (dockerd) not installed by setup-root.sh

**Where:** `setup-root.sh` Step 2c
**What happened:** setup-root.sh installed `docker-ce-cli` and `docker-ce-rootless-extras` but not `docker-ce` (which contains `dockerd`). setup-user.sh then failed: `/usr/bin/dockerd-rootless.sh: exec: dockerd: not found`.
**Fix:** Add `docker-ce` to the apt install list in setup-root.sh Step 2c.

---

### Bug 8 — Whisper image tag `latest-cpu` no longer exists

**Where:** `.env.template` and `docker-compose.yml`
**What happened:** `onerahmet/openai-whisper-asr-webservice:latest-cpu` returns "manifest unknown" — the tag was renamed. The CPU-only image is now just `latest`. The tag was hardcoded in both `docker-compose.yml` (as the default) AND `.env.template` (which overrides it), so fixing only the compose file was not enough.
**Fix:** Updated both files to use `latest`.
**Deeper fix:** Don't use floating tags like `latest-cpu` in `.env.template` — they silently break when upstream renames them. Either pin to a specific version (e.g. `v1.9.1`) or remove from `.env.template` entirely and rely on the compose default.

---

### Bug 9 — openclaw.json config schema mismatch → startup failure

**Where:** `setup-user.sh` — openclaw installation and config
**What happened:** The `openclaw.json` bundled in the deploy package contained keys the installed openclaw version doesn't recognize: `version`, `profiles`, `routing`, `providers`, `mcp`, `skills_dir`, `memory_dir`, `log_level_env`, `channels.telegram.token_env`, `channels.telegram.allowed_chat_ids`, `memory.embeddings`. openclaw refused to start. setup-user.sh exited with code 1 — even though all Docker services had started successfully.
**Fix applied:** `openclaw doctor --fix` stripped the unknown keys.
**Fix needed:** setup-user.sh should automatically run `openclaw doctor --fix` after installation. The bundled `openclaw.json` needs to be kept in sync with the installed openclaw npm package version.

---

### Bug 10 — `openclaw` binary not in PATH for non-interactive SSH sessions

**Where:** Any SSH command that calls `openclaw` (CLAUDE.md wizard + troubleshooting steps)
**What happened:** openclaw installs to `~/.npm-global/bin/`. This is added to `.bashrc` but non-interactive SSH sessions don't source `.bashrc`, so `openclaw` is "command not found."
**Fix:** Add `~/.npm-global/bin` to `~/.profile` (sourced by SSH) or `/etc/environment`. All CLAUDE.md SSH commands that call `openclaw` should use the full path `~/.npm-global/bin/openclaw` until this is fixed.

---

### Bug 11 — `openclaw restart` / `openclaw start` commands don't exist

**Where:** CLAUDE.md Steps 4a, 4c, and Troubleshooting section
**What happened:** CLAUDE.md repeatedly instructs `openclaw restart` and `openclaw start`. Neither command exists. The gateway is managed via `openclaw gateway install` (first time) and `systemctl --user restart openclaw-gateway.service` (thereafter).
**Fix:** Update all CLAUDE.md references accordingly.

---

## SECTION 2: UX & Wizard Issues

---

### UX 1 — Tailscale auth links expire quickly; multiple processes invalidate each other

**What happened:** Each call to `tailscale up` generates a new auth token, invalidating the previous one. The wizard ran `tailscale up` multiple times (background + foreground), causing the user to click an already-invalidated link. Links also expire in ~10 minutes if unused.
**Fix:** Kill any existing `tailscale up` processes before generating a new link. Show only one link at a time. Add a note in the wizard: "You have about 10 minutes to click this link."
**Enhancement:** Use `tailscale up 2>&1 | tee` and parse the URL in real-time rather than polling `tailscale status`. Consider using `--qr` flag if supported (shows scannable QR code).

---

### UX 2 — Hetzner web console unusable (no root password set)

**What happened:** During the server lockout, the wizard directed the user to the Hetzner web console. But Hetzner VPS instances created with SSH key authentication have no root password set by default — so the web console login prompt cannot be completed. The user tried many times before we found the rescue system.
**Fix:** Add to CLAUDE.md prerequisites: "Note: If you need emergency console access, set a root password in Hetzner *before* deployment (Server → Rescue → Reset Root Password). Without this, the web console is inaccessible."
**Better fix:** Don't let the deployment get into a lockout state in the first place (see Bug 5/6).

---

### UX 3 — Age key backup prompt is buried in setup output

**What happened:** setup-user.sh prints a prominent "CRITICAL: BACK UP YOUR AGE KEY" banner, but in non-interactive mode it's buried in hundreds of lines of Docker pull progress output. The CLAUDE.md wizard (Step 4b) says to pause here and wait for user confirmation — but the key is already printed by setup-user.sh, not shown separately by the wizard.
**Fix:** CLAUDE.md Step 4b should fetch and display the age key *after* setup-user.sh completes (via `cat ~/.config/age/keys.txt`), not rely on it appearing in the script output. This is already how CLAUDE.md describes it — but setup-user.sh should *not* print it (or print it more subtly), to avoid confusion about where to look.

---

### UX 4 — setup-user.sh exits with error even when services are running

**What happened:** setup-user.sh exited with code 1 due to openclaw config issues — after all four Docker containers had started successfully. From the wizard's perspective this was a failure, but from the user's perspective their services were actually running.
**Fix:** setup-user.sh should distinguish between "Docker services failed to start" (fatal) and "openclaw config needs fixing" (recoverable). Run `openclaw doctor --fix` automatically and continue rather than aborting.

---

### UX 5 — No pre-flight check for Docker image tags

**What happened:** The Whisper image tag `latest-cpu` failed at pull time, aborting the entire Docker stack launch after all images had already started downloading (wasting time). Other images had to restart.
**Fix:** Add a pre-flight step before `docker compose up` that validates each image tag exists on the registry. A simple `docker manifest inspect <image>:<tag>` for each service would catch this instantly.

---

### UX 6 — No progress visibility during long operations

**What happened:** Several steps (system update, Docker image pulls, Mistral download) take 5–20 minutes with no meaningful progress shown to the user in the wizard. The user repeatedly asked "Is it running?" and "What is going on?"
**Fix:** The wizard should give time estimates for each step. For image pulls especially, show something like "Downloading Docker images — this takes 3–5 minutes on a typical VPS connection. I'll update you when done."

---

### UX 7 — setup scripts not idempotent enough for error recovery

**What happened:** Every time a script failed, re-running it repeated all the expensive early steps (apt update, apt install, Docker install) even if they had already succeeded. This added 3–5 minutes per retry.
**Fix:** Each step should have a clear completion check at the top. If the step is already done (binary exists, package installed, service running), skip it immediately with an info message. Most steps already do this — but the expensive apt steps (`apt-get upgrade`) re-run every time regardless.

---

### UX 8 — No recovery path documented for partial failures

**What happened:** When setup-root.sh failed partway through, there was no guidance on what state the server was in or how to safely re-run. The wizard instructions assume a clean run.
**Fix:** Add a "Resuming after failure" section to CLAUDE.md that explains:
- If deploy.sh failed: fix the issue, re-run deploy.sh
- If setup-root.sh failed before Step 7 (SSH/UFW): SSH is still on port 22, safe to re-run
- If setup-root.sh failed at/after Step 7: SSH may be on port 2222 or server may be locked out
- If setup-user.sh failed: SSH on port 2222, Docker may or may not be running

---

## SECTION 3: Security & Architecture Concerns

---

### Security 1 — UFW/SSH ordering creates lockout risk

Already covered in Bugs 5/6. The root fix is architectural: never enable a firewall that blocks your only access method until you have confirmed that access works on the new configuration.

---

### Security 2 — openclaw gateway has no auth configured by default

**What happened:** `openclaw doctor` reported "CRITICAL: Gateway auth missing on loopback" and "CRITICAL: Browser control has no auth." `openclaw gateway install` auto-generated a token, but setup-user.sh didn't configure this proactively.
**Fix:** setup-user.sh should run `openclaw gateway install` (which auto-generates the token) as part of the standard setup flow, rather than leaving it for the wizard or the user to trigger manually.

---

### Security 3 — `.env` file left on VPS in plaintext

**What happened:** `~/compose/.env` contains all API keys in plaintext. While age encryption of `.env.enc` is good, the live compose `.env` is readable by anyone with openclaw user access. This is documented in setup-user.sh comments ("necessarily plaintext for Docker Compose") but worth calling out explicitly.
**Improvement:** Document this clearly in the handoff. Consider using Docker secrets or environment injection at runtime for a future version.

---

## SECTION 4: Deployment Package Maintenance

---

### Maintenance 1 — Hardcoded image versions will go stale

**Affected files:** `.env.template`, `docker-compose.yml`
**Issue:** n8n (1.85.4), Uptime Kuma (1.23.13), Ollama (0.6.2) are pinned to specific versions. These will become outdated. The Whisper image used a floating tag that broke. There's no process for keeping these current.
**Fix:** Add a `check-versions.sh` script that queries Docker Hub / GitHub for the latest versions of each image and reports what needs updating. Run this before each release of the deployment package.

---

### Maintenance 2 — openclaw.json must stay in sync with openclaw npm version

**Issue:** The bundled `openclaw.json` will break again whenever the openclaw config schema changes. There's no version locking or compatibility check.
**Fix:** setup-user.sh should always run `openclaw doctor --fix` after installation. Alternatively, ship a minimal `openclaw.json` with only essential keys that are unlikely to change.

---

### Maintenance 3 — No smoke test before release

**Issue:** All 12 bugs were discovered by actually running the deployment. A pre-release smoke test on a fresh VPS would have caught most of them.
**Fix:** Add a `test.sh` (already exists in the package — ensure it covers the full deployment path) and run it against a fresh Hetzner VPS before releasing any update to the deployment package.

---

## SECTION 5: CLAUDE.md Wizard Accuracy

The following specific items in CLAUDE.md are wrong or need updating:

| Location | Current text | Fix |
|----------|-------------|-----|
| Step 2 SSH key example | `~/.ssh/id_ed25519` | `$HOME/.ssh/id_ed25519` |
| Step 3a SSH command | port 22 | port depends on setup state; wizard should detect |
| Step 4a/4c | `openclaw status`, `openclaw restart` | `~/.npm-global/bin/openclaw status`, `systemctl --user restart openclaw-gateway.service` |
| Troubleshooting: openclaw daemon | `openclaw restart` | `systemctl --user restart openclaw-gateway.service` |
| Troubleshooting: openclaw doctor | `openclaw doctor` | `~/.npm-global/bin/openclaw doctor` |
| Prerequisites | No mention of root password | Add: set root password for emergency console access |
| Step 3b | No warning about link expiry | Add: "You have ~10 minutes to click this link" |
| Step 3b | No guidance on re-generating link | Add: how to get a fresh link if it expires |

---

---

## SECTION 5.5: Discord Integration Learnings (added 2026-03-01)

These were discovered when connecting OpenClaw 2026.2.26 to Discord after full deployment.
All items are now captured in CLAUDE.md Step 4.5 for automatic setup on future deployments.

---

### Discord 1 — Discord plugin is disabled by default

**What happened:** Running `openclaw channels add --channel discord --token <TOKEN>` failed with
`"Unknown channel: discord"`. The Discord channel type was not recognized.
**Root cause:** OpenClaw's plugin system starts with non-core plugins disabled. Discord is a plugin,
not a built-in channel.
**Fix:** Before adding the Discord channel, run `openclaw plugins enable discord` then restart
the gateway. Now captured in CLAUDE.md Step 4.5b.

---

### Discord 2 — API keys must be in the gateway systemd service env, not compose/.env

**What happened:** After configuring the Discord channel, the bot received messages but produced no
responses. Logs showed the agent received messages but there was no LLM call.
`openclaw models list` showed `Auth: no` for all Anthropic models.
**Root cause:** `ANTHROPIC_API_KEY` (and OpenAI, Google keys) are set in `~/compose/.env` which is
read by Docker Compose containers — not by the gateway systemd service. The gateway has a separate
process environment.
**Fix:** Create `~/.config/systemd/user/openclaw-gateway.service.d/api-keys.conf` with:
```ini
[Service]
Environment=ANTHROPIC_API_KEY=<key>
Environment=OPENAI_API_KEY=<key>
Environment=GOOGLE_API_KEY=<key>
```
Then `systemctl --user daemon-reload && systemctl --user restart openclaw-gateway.service`.
This file must be chmod 600. Now captured in CLAUDE.md Step 4.5a.

---

### Discord 3 — Channel config key must be channel NAME, not numeric channel ID

**What happened:** Used the Discord numeric channel ID (e.g., `1477705724804202568`) as the key
in `guilds.<serverID>.channels`. Gateway logs showed:
`channels unresolved: <serverID>/<channelID>` at every startup.
**Root cause:** OpenClaw's Discord plugin resolves channel allowlists by looking up channel NAMES
via the Discord API. The key in the config JSON is treated as a channel name to search for —
a numeric string like "1477705724804202568" is searched as a name and not found.
**Fix:** Use the channel's display name (e.g., "commands" for #commands), not the numeric ID.
After fix, logs show: `discord channels resolved: <serverID>/commands→<serverID>/<channelID>`.
Now captured in CLAUDE.md Step 4.5c with a callout note.

---

### Discord 4 — requireMention defaults to true; bot ignores messages without @mention

**What happened:** After fixing channel resolution, the bot still didn't respond. Gateway logs
showed `discord: skipping guild message reason: no-mention`.
**Root cause:** For guild (server) channels, OpenClaw defaults to `requireMention: true`, meaning
it ignores messages that don't @mention the bot. This is intentional to prevent the bot from
responding to every message in busy servers.
**Fix:** Set `requireMention: false` at BOTH the guild level AND the channel level:
```json
"guilds": {
  "<serverID>": {
    "requireMention": false,
    "channels": {
      "commands": { "requireMention": false }
    }
  }
}
```
Setting it at only one level is not sufficient. Now captured in CLAUDE.md Step 4.5c.

---

### Discord 5 — Default model is claude-opus-4-6 (very expensive)

**What happened:** OpenClaw 2026 defaults to `anthropic/claude-opus-4-6` for all requests.
Every simple question (including one-line answers) used the most expensive model.
**Fix applied:**
1. Change default to `anthropic/claude-sonnet-4-6` via `openclaw models set`
2. Add aliases: `fast` → haiku, `capable` → opus, `local` → ollama/mistral
3. Update SOUL.md with model selection guidance so the AI suggests switching when appropriate
Now captured in CLAUDE.md Step 4.5d.

---

### Discord 6 — "Message Content Intent is limited" is informational, not an error

**What happened:** After enabling the Discord channel, gateway logs showed:
`discord: Message Content Intent is limited to verified bots in large servers`
This caused concern about whether the integration would work.
**Root cause:** This is a Discord API informational message meaning the Message Content Intent
is restricted for bots in 100+ server guilds. For bots in fewer servers (unverified), the
intent works fully. It does NOT indicate failure.
**Fix:** No action needed. Verify the intent is enabled in Discord Developer Portal
(Bot → Privileged Gateway Intents → Message Content Intent). If enabled, messages work fine
regardless of this log message.

---

### Discord 7 — Full working discord config for reference

```json
{
  "channels": {
    "discord": {
      "enabled": true,
      "token": "<BOT_TOKEN>",
      "groupPolicy": "allowlist",
      "dmPolicy": "pairing",
      "streaming": "off",
      "allowFrom": ["<YOUR_DISCORD_USER_ID>"],
      "guilds": {
        "<SERVER_ID>": {
          "requireMention": false,
          "channels": {
            "<CHANNEL_NAME>": {
              "requireMention": false
            }
          },
          "users": ["<YOUR_DISCORD_USER_ID>"]
        }
      }
    }
  },
  "plugins": {
    "entries": {
      "discord": { "enabled": true }
    }
  }
}
```
Where:
- `<CHANNEL_NAME>` = channel's display name (e.g., "commands"), NOT the numeric channel ID
- `groupPolicy: "allowlist"` = bot only responds in explicitly listed server/channels
- `dmPolicy: "pairing"` = DMs require pairing handshake
- `streaming: "off"` = required for Discord (streaming not supported on Discord)

---

## SECTION 6: What Went Well

Worth preserving in future versions:

- **Rescue system recovery** worked cleanly once we found the right approach (edit ufw.conf directly)
- **Idempotency of most steps** — re-running setup-root.sh skipped completed steps quickly
- **age + sops graceful fallback fix** was straightforward and didn't require bypassing security
- **Docker rootless** worked correctly once `docker-ce` was installed
- **Tailscale** connected immediately once authorized
- **All four services came up** on the first successful `docker compose up`
- **openclaw gateway install** was simple and self-configuring (auto-generated auth token)

---

## Summary: Priority Fixes for v2

**Must fix before next deployment (will cause failure):**
1. Add `docker-ce` to setup-root.sh package list (Bug 7)
2. Fix SSH service name: `ssh.service` not `sshd.service` (Bug 5)
3. Restart SSH *before* enabling UFW (Bug 6)
4. Fix Whisper image tag in `.env.template` (Bug 8) ✓ done
5. Run `openclaw doctor --fix` + `openclaw gateway install` in setup-user.sh (Bugs 9, Security 2)
6. Fix tilde expansion in deploy.sh (Bug 1)

**Should fix (causes user confusion):**
7. Graceful checksum fallback for age/sops/compose (Bugs 2/3/4) ✓ done
8. Add PATH fix for openclaw binary (Bug 10)
9. Fix CLAUDE.md openclaw command references (Bug 11, CLAUDE.md section)
10. Add Docker image tag pre-flight validation (UX 5)
11. Document recovery paths for partial failures (UX 8)
12. Add root password advisory to prerequisites (UX 2)

**Nice to have:**
13. Better Tailscale link handling (UX 1)
14. Time estimates for long steps (UX 6)
15. Version check script for image tags (Maintenance 1)
16. Full smoke test on fresh VPS before release (Maintenance 3)

---

## SECTION 7: Mac Node (Post-Deployment) — Session 2026-03-01

These bugs were found while adding a Mac node for Claude Code-style terminal access via Discord.
They do not affect the initial deployment — they apply to anyone setting up a compute node.

---

### Mac Node Bug B13 — `bind: tailnet` crashes without allowedOrigins

**What happened:** Changing `gateway.bind` to `"tailnet"` causes crash: "non-loopback Control UI
requires gateway.controlUi.allowedOrigins". Even with `dangerouslyAllowHostHeaderOriginFallback=true`,
the Mac node's security check blocks `ws://` to non-loopback IPs.
**Fix:** Use `bind: loopback` and an SSH port-forward tunnel instead. The tunnel is Tailscale-protected
(only Tailscale devices can reach port 2222), so this is actually more secure.
**Lesson:** Do not attempt `bind: tailnet` for a Mac node setup. Use the SSH tunnel approach.

---

### Mac Node Bug B14 — SSH has `AllowTcpForwarding no` blocking the tunnel

**File:** `/etc/ssh/sshd_config.d/99-openclaw.conf`
**What happened:** SSH tunnel failed with "administratively prohibited: open failed".
setup-root.sh writes `AllowTcpForwarding no` which blocks all port forwarding.
**Fix applied to setup-root.sh:** Changed `AllowTcpForwarding no` → `AllowTcpForwarding local`
(allows local forwards only — more secure than `yes`, still enables the SSH tunnel).

---

### Mac Node Bug B15 — Mac node auth token changes after first pairing

**What happened:** Mac node authentication uses two different tokens:
1. Initial pairing: use the OPERATOR token as `OPENCLAW_GATEWAY_TOKEN`. Gateway auto-approves,
   assigns role=node, and stores a node-specific token in `~/.openclaw/identity/device-auth.json`.
2. After pairing: `OPENCLAW_GATEWAY_TOKEN` must be set to the NODE-ROLE token from `device-auth.json`.
**Fix:** After first successful connection, update the LaunchAgent plist to use the node-role token
from `~/.openclaw/identity/device-auth.json → tokens.node.token`.
Check if `openclaw node install` handles this automatically — if not, this manual step is required.

---

### Mac Node Bug B16 — exec-approvals.json security defaults to `deny`

**File:** `~/.openclaw/exec-approvals.json`
**What happened:** Adding `**` to `agents.*.allowlist` does NOT enable exec. The default `security`
mode is `"deny"` which blocks ALL shell commands with `SYSTEM_RUN_DISABLED` regardless of allowlist.
**Root cause:** `DEFAULT_SECURITY = "deny"` in exec-approvals source. The `security` field must be
explicitly set to `"full"` to allow all commands, or `"allowlist"` to use pattern matching.
**Fix:** Use the gateway API — NOT direct file editing (see B17):
```bash
echo '{"version":1,"defaults":{"security":"full"},"agents":{}}' | \
  openclaw approvals set --node "YourNodeName" --stdin
```

---

### Mac Node Bug B17 — exec-approvals.json is overwritten on node startup

**What happened:** Direct edits to `~/.openclaw/exec-approvals.json` are lost every time the
node process restarts. The node initializes a fresh config on startup.
**Fix:** Always use `openclaw approvals set --node "NodeName" --stdin` or
`openclaw approvals allowlist add --node "NodeName"` to configure exec approvals.
These commands persist the config via the gateway API.

---

### Mac Node Bug B18 — Docker container healthchecks broken (n8n, Ollama, Whisper)

**File:** `docker-compose.yml`
**Fixed in this package.**
- **n8n:** `localhost` inside the container resolves to `[::1]` (IPv6) but n8n listens on IPv4 only.
  Fix: use `127.0.0.1` explicitly.
- **Ollama:** Container has no `curl` binary. Fix: use `OLLAMA_HOST=127.0.0.1:11434 ollama list`.
- **Whisper:** `/health` endpoint doesn't exist (returns 405). Fix: check for any HTTP response
  on `/asr` (which also returns 405 for GET — but that means the service is up).

---

### Mac Node Bug B19 — External Whisper health check uses wrong endpoint + `-f` flag

**File:** `setup-user.sh` (end-of-script health checks), `CLAUDE.md` Step 5
**Fixed in this package.**
The health checks used `curl -sf http://HOST:9000/health` which fails because:
1. `/health` doesn't exist on the Whisper container (returns 405).
2. The `-f` flag causes curl to fail on any 4xx response.
Fix: check for any HTTP response on `/asr` without `-f`.

---

### Mac Node Bug B20 — AI agent CLI timeout too short

**What happened:** `timeout 60` is not enough for end-to-end AI agent calls — the model response,
node execution, and result formatting together often exceed 60 seconds.
**Fix:** Use `timeout 120` or longer for verification commands involving the AI agent.

---

### Mac Node Bug B21 — VPS `exec` tool does not exist despite being in `tools.allow`

**File:** `~/.openclaw/openclaw.json` on VPS
**What happened:** Adding `"exec"` to `tools.allow` has no effect. The exec tool is not a built-in
gateway capability in OpenClaw v2026.2.26. The AI agent has 8 tools: `read`, `write`, `web_search`,
`web_fetch`, `nodes`, `message`, `memory_search`, `memory_get` — no shell exec primitive.
**Impact:** VPS-local command execution is not available without an additional compute node setup.
For VPS file access, use the `read` tool (reads arbitrary VPS files).
**Fix:** Update SOUL.md to accurately describe VPS fallback capabilities (read/write, not exec).

---

## SECTION 8: Session 3 Bugs (B22-B28) — 2026-03-02

---

### B22 [FIXED] Drop-zone systemPrompt used web_fetch for private Tailscale IP

**What happened:** User dropped URL in #drop-zone. Discord said "Processing..." but no pipeline card appeared.
Gateway log showed: `blocked URL fetch target=http://100.94.99.89:5678/webhook/research-get reason=Blocked hostname or private/internal/special-use IP address`
**Root cause:** OpenClaw gateway security layer blocks web_fetch to RFC-1918 / Tailscale addresses. The systemPrompt instructed the AI to use web_fetch on 100.94.99.89.
**Fix:** Updated systemPrompt to use exec tool (runs curl on Mac node, which has Tailscale access to VPS). Also fixed endpoint: GET /webhook/research-get → POST /webhook/research-intake with JSON body.

---

### B23 [FIXED] Orphaned "Research Intake — GET Bridge" workflow (nQEF9h2euWjSitII)

**What happened:** Stale debug workflow left active, consuming webhook namespace.
**Fix:** Deleted via n8n API.

---

### B24 [DOCUMENTED] "Unknown Channel" error after failed web_fetch

**What happened:** After web_fetch failed (B22), Claude retried and eventually tried to post a response but got `message failed: Unknown Channel` ~4 min later.
**Root cause:** Discord WebSocket reconnect clears channel cache. After a failed agent loop, the channel reference went stale.
**Fix:** Fixing B22/B23 eliminates the retry loop. This error disappears once the systemPrompt is corrected.

---

### B25 [VERIFIED] n8n SSH key presence in authorized_keys

**What happened:** grep for "n8n" in authorized_keys returned nothing (key comment is `openclaw@ubuntu-4gb-ash-1`, not "n8n").
**Root cause:** False alarm — the key IS present. The comment on the RSA key doesn't contain "n8n".
**Fix:** Verified by matching public key fingerprint against authorized_keys content. Key confirmed present.

---

### B26 [DEFERRED] No error handling in pipeline branches — silent failures

**What happened:** When upstream API calls fail (GitHub API rate limit, Claude error, etc.), pipeline fails silently with no Discord notification.
**Fix:** Added continueOnFail to all HTTP Request and SSH nodes. Added error detection in Format Card nodes. Added error card output path. Deployed in pipeline rebuild (Session 3).

---

### B27 [FIXED] research-log.ndjson missing — no deduplication or reading log

**What happened:** Duplicate URLs were processed every time they were dropped.
**Fix:** Added SSH dedup check node (reads research-log.ndjson, skips known URLs). Added SSH log-to-file nodes after each Discord post. Deployed in pipeline rebuild (Session 3).

---

### B28 [FIXED] .env.template had outdated N8N_IMAGE_TAG=1.85.4

**What happened:** New deployments would install n8n 1.85.4 which had broken SSH RSA key support.
**Fix:** Changed N8N_IMAGE_TAG=1.85.4 → N8N_IMAGE_TAG=latest in .env.template.

---

## SECTION 9: Research Pipeline — Social Media Extension (Session 4, 2026-03-02)

Added social media URL support (Twitter/X, Bluesky, LinkedIn, Instagram) to the n8n research
intake pipeline. Goal: drop any social media post about a paper/repo and auto-find the source.

---

### B29 [FIXED] URL Classifier had no social media detection

**What happened:** Instagram, Twitter/X, Bluesky, and LinkedIn URLs were classified as `article`
and processed through the general article branch, which just scraped the page as text — useless
for social media.
**Fix:** Added social media detection to URL Classifier. Added `_depth` field to prevent
resubmitted URLs (depth≥1) from re-entering the social branch (loop prevention). Social branch
only fires at depth=0.

---

### B30 [FIXED] Instagram HTML scraping returns JS shell — no caption content

**What happened:** `SM: Fetch Post` (HTTP GET) returned a 900KB HTML file with zero actual
content — only CSS bundles and JS app code. Instagram moved to a fully JS-rendered architecture;
no post content exists in the initial HTML even with a valid `sessionid` cookie.
**Root cause:** Instagram's modern architecture requires JS execution to render post content.
A simple HTTP GET, even authenticated, only gets the app shell.
**Fix:** Added `SM: IG Fetch` SSH node that calls `~/scripts/ig_fetch.py` for Instagram URLs.
The script uses `instagrapi` (Python library) which uses the Instagram mobile API — bypassing the
web JS requirement entirely.
**Note:** Other platforms (Twitter/X, Bluesky, LinkedIn) still work via HTTP GET + OG tag
extraction since they serve content in the initial HTML.

---

### B31 [FIXED] instagrapi login from VPS fails — datacenter IP blacklisted by Instagram

**What happened:** `instagrapi` login from the VPS (Hetzner datacenter IP) immediately returned:
`"change your IP address, because it is added to the blacklist of the Instagram Server"`
**Root cause:** Instagram blocks authentication attempts from known datacenter/VPS IP ranges.
Real users don't log in from Hetzner servers.
**Fix:** Log in once from Mac (residential IP), save the session JSON, copy to VPS. The VPS
reuses the saved session without re-authenticating. Session lasts ~90 days.
**Session renewal procedure:**
1. `python3 /tmp/ig_login.py` on Mac (handles email verification challenge)
2. `scp -P 2222 /tmp/ig_session.json openclaw@100.94.99.89:~/.config/ig_session.json`

---

### B32 [FIXED] SM: IG Fetch SSH command only escaped double quotes — command injection risk

**Where:** `SM: IG Fetch` SSH node in `build_pipeline.py`
**What happened:** The URL was only sanitized with `.replace(/"/g, '\\"')` before being
interpolated into the shell command. URLs containing backticks, dollar signs, or backslashes
could break out of the quoted string or execute arbitrary shell commands.
**Fix:** Applied full 4-character escape matching the pattern used in `ssh_log()`:
`.replace(/\\/g,'\\\\').replace(/"/g,'\\"').replace(/$/g,'\\$').replace(/`/g,'\\`')`

---

### B33 [FIXED] SM: Build Rank Req used literal string "null" as Brave search query

**What happened:** When `search_query` was JSON null (Claude found nothing to search for —
typically the login-wall case), JS template literal coercion converted it to the string "null".
Brave then searched for "null" and returned Instagram's homepage, which Claude correctly
identified as not being the source. Functionally correct but wasteful (one Brave query + one
Claude call for nothing).
**Fix:** Added `contentEmpty` guard in `SM: Build Rank Req`: if both `search_query` is null AND
`_extracted_text` is empty, immediately return the rank-skip response without calling Brave.
This eliminates the wasted API calls on login-wall Instagram posts.

---

### B34 [NOTE] ig_fetch.py Instagram session credentials storage

**Files:** `~/.config/ig_session.json`, `~/.config/ig_creds.json` on VPS
- Session JSON (~1.5KB): instagrapi session state, renewed from Mac after expiry
- Creds JSON: `{"username": "eye0396", "password": "..."}` — chmod 600
- `ig_fetch.py` uses saved session on load; falls through to full login on session expiry
- Session typically lasts 90+ days before Instagram invalidates it
- **Do NOT commit session or creds files to git** — they are on the VPS only

---

### B35 [FIXED] YouTube branch didn't process papers/repos found in video descriptions

**What happened:** YouTube videos about research papers had arxiv/GitHub links in their
descriptions but the pipeline only posted the video summary card — the actual paper was never
processed.
**Fix:** Added `YT: Extract Sources` + `YT: Resubmit Sources` nodes that fan out from
`YT: Call Claude` in parallel with `YT: Format Card`. Extracts up to 3 arxiv/GitHub links
from Claude's parsed JSON response and resubmits each at depth=1 to the intake webhook.

---

## SECTION 10: Code Audit Findings (2026-03-02)

Static review of all scripts and support files. No deployment was run — findings based on
code analysis only.

---

### B36 [FIXED] `scripts/build_save_workflow.py` contained hardcoded secrets

**File:** `scripts/build_save_workflow.py` (now deleted)
**What was there:** n8n API key (JWT) hardcoded at line 6; Discord webhook URL hardcoded at
line 9. The file was not referenced anywhere in the codebase — its functionality was fully
superseded by `build_pipeline.py`.
**Fix:** File deleted.

---

### B37 [FIXED] `.gitignore` missing Instagram credential file patterns

**File:** `.gitignore`
**What happened:** `ig_creds.json` and `ig_session.json` live on the VPS at `~/.config/`, but
if a user accidentally copies them locally they would be committed to git.
**Fix:** Added `ig_creds.json` and `ig_session.json` to `.gitignore`.

---

### B38 [FIXED] `setup-n8n.sh` missing `BRAVE_API_KEY` — fresh installs fail at pipeline step

**File:** `scripts/setup-n8n.sh` lines 13–17 (required-var check) and lines 56–63 (build_pipeline.py invocation)
**What happened:** `build_pipeline.py` requires `--brave-api-key` and exits with an error if
not provided. `setup-n8n.sh` called `build_pipeline.py` without `--brave-api-key`, so any
fresh deployment via `setup-n8n.sh` would fail at step 6.
**Fix:** Added `[[ -z "$BRAVE_API_KEY" ]] && error "..."` to required-var check; added
`--brave-api-key "$BRAVE_API_KEY"` to the `build_pipeline.py` invocation. Also updated
CLAUDE.md Step 7c to include `BRAVE_API_KEY` in the invocation example.

---

### B39 [FIXED] `setup-n8n.sh` drop-zone systemPrompt was outdated (no social media handling)

**File:** `scripts/setup-n8n.sh` lines 73–83 (embedded Python `new_prompt` string)
**What happened:** The embedded systemPrompt only handled generic URL processing with a single
confirmation message. It had no social media URL type detection, no differentiation between
arxiv/github/youtube/social, and no mention of the social branch.
Fresh deployments via `setup-n8n.sh` would configure the bot without social media support,
inconsistent with the pipeline's actual capabilities.
**Fix:** Updated `new_prompt` to match current behavior — type detection for arxiv, github,
instagram/twitter/bluesky/linkedin, youtube, and other URLs, with appropriate response text
for each. Matches the systemPrompt used in production.

---

### B40 [FIXED] `build_pipeline.py` had dead `_require()` function (lines 12–17)

**File:** `scripts/build_pipeline.py`
**What happened:** `_require()` was defined but never called anywhere. All required-var
validation goes through argparse (lines 41–50). The function was a leftover from before
argparse was added.
**Fix:** Removed the dead function.

---
