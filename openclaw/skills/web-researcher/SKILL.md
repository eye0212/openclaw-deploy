---
name: web-researcher
description: Search the web, fetch pages, and produce structured research summaries
version: 1.0.0
user-invocable: true
requires:
  config: []
---

# Skill: Web Researcher

## Purpose

Search the web, fetch and read pages, and synthesize findings into structured markdown research reports. Useful for fact-checking, competitive research, technical deep-dives, and summarizing current events.

## How to Use

Send a research query or question. The assistant will:

1. Use `web_search` to find relevant sources
2. Use `web_fetch` to read key pages in full
3. Synthesize findings into a structured report

### Example prompts

```
research: What are the main differences between Ollama and vLLM?
research: Latest news on Tailscale exit nodes
research: How does nomic-embed-text compare to other embedding models?
```

Or just ask a question naturally — the assistant will recognize when web research is needed.

## Output Format

Reports follow this structure:

```markdown
## Summary
[2–3 sentence overview]

## Key Findings
- Finding 1 (source)
- Finding 2 (source)
- ...

## Sources
1. [Title](URL)
2. [Title](URL)
```

## Routing

This skill uses the `default` LLM profile (Claude Sonnet) for synthesis and analysis.
Web search and fetch are handled by the `web_search` and `web_fetch` built-in tools.

## Notes

- All web fetches happen server-side; no browser required
- For time-sensitive queries, include "as of today" or a date to anchor results
- Maximum ~10 sources per report to keep responses focused
