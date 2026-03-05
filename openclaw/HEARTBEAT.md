# Heartbeat Checklist

## Every 30 minutes
- Check service health (n8n, Ollama, Whisper, Uptime Kuma containers running?)
- Check stock alerts if market is open (any ticker moved >3%?)
- Check blogwatcher for new posts from monitored feeds

## Morning briefing (7:00 AM ET, cron: morning-briefing)
- Weather forecast for New York today
- Today's Google Calendar events (if Gmail/Calendar configured)
- Unread email count + any flagged/important subjects (if Gmail configured)
- Overnight stock portfolio moves
- New arxiv papers or blog posts overnight
- Send consolidated briefing to Discord #commands

## Evening preview (9:00 PM ET, cron: evening-preview)
- Tomorrow's calendar preview
- Unread email count
- End-of-day stock summary

## Weekly summary (Monday 8:00 AM ET, cron: weekly-summary)
- Weekly portfolio performance
- Research pipeline stats (URLs processed this week from research-log.ndjson)
- VPS disk usage and service uptime
