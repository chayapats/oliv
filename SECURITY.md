# Security Policy

## Supported versions

Only the **latest GitHub release** of OLIV is supported.

## What this app touches

OLIV is a macOS menu-bar dictation app. It holds a push-to-talk hotkey, records
the microphone while that key is down, transcribes on-device, and pastes into
the frontmost app (Accessibility / Input Monitoring). Cloud STT is **off by
default** and only runs if someone opts in with their own API key.

Please treat anything that could leak audio, transcripts, API keys, or
unexpected network calls as a security issue.

## Reporting a vulnerability

**Do not open a public issue** for security reports.

1. Use GitHub's private [vulnerability reporting](https://github.com/chayapats/oliv/security/advisories/new) (preferred), or
2. Email **chayapat.premium@gmail.com** with a description, impact, and how to reproduce.

You should hear back within a few days. Please give time to ship a fix before
any public disclosure.

Copy Diagnostics (the menu item) is meant for ordinary bug reports: it does not
include transcripts or API keys. Do not attach recordings or secret keys to a
public issue.
