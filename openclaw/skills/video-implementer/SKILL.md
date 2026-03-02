---
name: video-implementer
description: Transcribe, summarize, and answer questions about video and audio files via local Whisper
version: 1.0.0
user-invocable: true
requires:
  env: []
  config: []
---

# Skill: Video Implementer

## Purpose

Process video and audio files: transcribe speech, extract key information, summarize content, and answer questions about media.

## Capabilities

- **Transcription**: Send a video or audio file → get a full transcript via Whisper
- **Summarization**: Get a concise summary of video content
- **Q&A**: Ask questions about a video's content
- **Key points**: Extract action items, decisions, or highlights
- **Translation**: Transcribe and translate to English (or specified language)

## How to Use

Send a video or audio file with one of these commands:

```
transcribe          → Full transcript
summarize           → 2-3 paragraph summary
keypoints           → Bullet-point highlights
qa: your question   → Answer a specific question about the content
translate           → Transcribe + translate to English
```

Or just send a file with no command — you'll get a summary by default.

## Supported Formats

Audio: mp3, wav, m4a, ogg, flac, aac
Video: mp4, mkv, webm, mov, avi (audio is extracted)

## Technical Details

- Transcription: [Whisper](https://github.com/openai/whisper) (local, self-hosted)
- Model: configurable via `WHISPER_MODEL` env var (default: `base`)
- Max file size: 500 MB
- Processing time: ~1x real-time for `base` model on CPU

## Routing

This skill uses the `default` LLM profile for analysis and the local Whisper service for transcription.

Whisper endpoint: `http://localhost:9000`
