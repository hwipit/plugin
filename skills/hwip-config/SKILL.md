---
name: hwip-config
description: >
  Set up Hwip: install the CLI, sign in in the browser, verify with a test push.
metadata:
  author: hwipit
  relatedSkills:
    - hwip
    - hwip-mode
  triggers:
    - hwip-config
    - setup hwip
    - configure hwip
    - hwip setup
    - api key
    - hook id
    - remote control setup
    - cross-device notifications setup
    - /hwip-config
---

Set up Hwip for the user. **The entire setup is install the CLI, then run
`hwip install`** — everything else in this skill is verification.

## The setup

```bash
npm install -g @hwip/cli
hwip install
```

The installer is interactive (browser sign-in + agent picker), so it must run
in the user's own terminal, not through your Bash tool. Ask them to run it —
inside a Claude Code session they can type it with a `!` prefix:

```
! npm install -g @hwip/cli && hwip install
```

**Install globally, not `npx`.** `hwip cc` (drive a session from the phone)
needs `hwip` on `PATH`, and the agent hooks the installer writes (like this
plugin's hooks and MCP server) are `command -v hwip || npx …` — a global binary
skips an npx cold-start on every notification and every session start. `npx -y @hwip/cli install` still works for a
notifications-only setup with no phone control, but default to the global
install.

What `hwip install` does:
- **Fresh machine**: opens a browser sign-in. The web app issues an API key
  and an interactive Hook **as a matched pair, automatically** — no copying
  keys from Settings. The CLI saves everything (`apiKey`, `hookId`,
  `baseUrl`, `wsUrl`) to `~/.hwip/config.json`.
- **Already signed in**: keeps the saved credentials and just (re)installs
  agent integrations. Safe to re-run any time.
- Installs hooks/MCP for every detected agent (Claude Code, Gemini CLI,
  Codex CLI, Cursor, …).

## Verify (after the user says it finished)

1. `hwip verify` (or `npx -y @hwip/cli verify`) — must report the API key
   and the hook as set. Never `cat ~/.hwip/config.json`: it holds the API
   key, and printing it puts the key in the transcript.
2. Send a test push: use `hwip_notify`, or
   `hwip notify --title "Hwip connected ✅"`.
3. Phone buzzed → done. Tell the user to restart their agent session so the
   SessionStart hook injects the remote-control rules.

## Rules — do NOT re-introduce the old manual flow

- **Single source of truth: `~/.hwip/config.json`.** Every Hwip component
  (CLI, MCP server, plugin hooks) reads it. Do NOT add `HWIP_API_KEY` /
  `HWIP_HOOK_ID` to `~/.zshrc`, `~/.bashrc`, or `~/.claude/settings.json` —
  shell exports are unnecessary and create a second, drift-prone copy.
- Env vars exist only as **advanced overrides** (multi-account, CI). Never
  suggest them during normal setup.
- Never walk the user through creating keys or hooks by hand in the web app
  unless the machine is headless (below).

## Headless machine (no browser)

Sign in on any machine WITH a browser. The user then reads the two values
(`apiKey`, `hookId`) from that machine's `~/.hwip/config.json` themselves —
don't print the file into the session, it holds the API key. On the headless
machine the user runs this in their own terminal (run by you, the key would land
in the transcript):

```bash
npm install -g @hwip/cli
hwip install --key ak_... --hook hook_...
```

## If things go wrong

**`hwip_ask` 403 Forbidden** — stale key/hook pairing. Re-run
`hwip install`; a fresh sign-in issues a consistent pair.

**No notification received** — `command -v jq` (hooks need jq:
`brew install jq` / `apt install jq`), and confirm the phone app is signed
in to the SAME account the browser sign-in used.

**`hwip_ask` times out** — phone app open? Answered within the timeout
(default 300 s)? `hwip verify` checks installation health.

**config.json missing or corrupt** — re-run `hwip install`; it rewrites
the file.
