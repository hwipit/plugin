# Hwip — notifications & remote control for AI coding agents

[![release](https://img.shields.io/github/v/release/hwipit/plugin?label=plugin&sort=semver)](https://github.com/hwipit/plugin/releases)
[![marketplace](https://img.shields.io/badge/claude--code-plugin-blueviolet)](https://github.com/hwipit/plugin)
[![cli](https://img.shields.io/npm/v/@hwip/cli?label=%40hwip%2Fcli)](https://www.npmjs.com/package/@hwip/cli)
[![mcp-server](https://img.shields.io/npm/v/@hwip/mcp-server?label=%40hwip%2Fmcp-server)](https://www.npmjs.com/package/@hwip/mcp-server)
[![license](https://img.shields.io/github/license/hwipit/plugin)](./LICENSE)
[![docs](https://img.shields.io/badge/docs-docs.hwip.app-1f6feb)](https://docs.hwip.app)

**Your agent finishes a build or hits a decision → your phone buzzes → you tap an answer → the session keeps going.** No walking back to the terminal.

Hwip turns any AI coding agent into something you can supervise from your pocket. Get a push the moment Claude finishes real work or needs a call, then answer right there — a button tap or a typed reply flows straight back into the live session.

<p align="center">
  <img src="https://hwip.app/readme/demo.gif" alt="Claude asks 'Deploy to prod?' on your phone; you tap Deploy; the session ships" width="560"><br>
  <sub><em>Claude asks on your phone → you tap <b>Deploy</b> → the session ships. No terminal.</em></sub>
</p>

Works with **Claude Code, Cursor, Windsurf, Gemini CLI, Codex, and more.** Built on [`@hwip/cli`](https://github.com/hwipit/cli) (installer, hooks, tmux remote control) and [`@hwip/mcp-server`](https://github.com/hwipit/mcp-server) (the `hwip_ask` family of tools), paired with the [Hwip app](https://hwip.app) on your phone.

> **New here?** [docs.hwip.app](https://docs.hwip.app) walks the whole setup — one command on your machine, the app on your phone, and a restart. The reference below assumes that is already done.

---

## Quick start

```bash
# 1. Add the Claude Code plugin
claude plugin marketplace add hwipit/plugin
claude plugin install hwip@hwip

# 2. Install the CLI and wire everything up (opens a browser sign-in)
npm install -g @hwip/cli
hwip install
```

Restart Claude Code — notifications start automatically. That's it. `hwip install` signs you in once, issues a matched API key + hook, and configures every AI agent it finds on your machine. Not near a browser? See [headless setup](#other-agents).

> **Why global, not `npx`?** A global `hwip` powers `hwip cc` (drive a session from your phone) and lets agent hooks and the plugin's MCP server skip an npx cold-start. `npx @hwip/cli install` still works for a notifications-only setup — without `hwip` on PATH, the hooks and the MCP server fall back to `npx -y @hwip/cli`.

---

## What you get

**Two things, out of the box:**

### 1. Notifications that just work — no prompting, 100% reliable

| You get a push when… | Fires on |
|----------------------|----------|
| Claude **asks you a question** | any `AskUserQuestion` |
| A session **has been idle for five minutes** (it's done) | the session going quiet, not each turn |
| Claude flags a turn as **important** | a `high` Push Signal on that response |
| Claude **finishes real work**, every turn | only after `/hwip-mode normal` — see below |

These ride on hooks — shell commands that fire on Claude events, independent of whether the model "remembers" to notify you. Out of the box the per-turn push is off (`quiet`), so a long session pings you when it asks something and when it's actually finished, not thirty times along the way. They fire in **every** Claude Code session, not only ones launched with `hwip cc` — that command is the phone-control bridge, not the notification switch. Dial the volume any time, per project or machine-wide (see [Mute & Push Mode](#mute--push-mode)).

### 2. Reply from your phone, straight into the session

With a Hook ID configured (`hwip install` sets one up automatically), Claude ends a turn by **asking you** — buttons *and* a text field, together. Tap **Continue** / **Review** / **Done**, or type `commit and push` / `/ship` / `fix the tests`. Your answer runs immediately, then Claude asks again. This is the **Ask Loop**, and it keeps going until you tap **Done**.

<p align="center">
  <img src="https://hwip.app/readme/ask-phone.png" alt="A Hwip hook on the phone: a question with tappable answer buttons and a text field" width="300">
</p>

| Tool | What it shows | When Claude reaches for it |
|------|---------------|----------------------------|
| `hwip_ask` | buttons **+** text input (text only without `actions`) | decisions, next steps, custom instructions, free-form input |
| `hwip_notify` · `hwip_clipboard` · `hwip_file` | one-way push | when you explicitly ask |
| `hwip_agent_send` | types a message into another agent session (shell form: `hwip agent send`) | when you ask it to pass something to another agent |
| `hwip_agent_list` · `hwip_agent_read` | lists the agent sessions on this machine and reads what one did last (this PC only, no API call; shell form: `hwip agent list` / `read`) | when you ask what another agent here is doing |

> `hwip_ask` needs a Hook ID — issued for you during sign-in and saved to `~/.hwip/config.json`. No env vars.

---

## Drive a session end-to-end from your phone

Launch Claude through `hwip cc` and the phone's **Active Agents** picker can type directly into the running session — even after a `hwip_ask` window has closed. Start a refactor from the couch, answer follow-ups over lunch, come back to a finished branch.

```bash
hwip cc          # claude in a named tmux session the phone can reach
hwip codex       # same for Codex
hwip gemini      # same for Gemini
```

One-step setup and the full architecture live in [cli → Remote Control](https://github.com/hwipit/cli#remote-control).

---

## Autonomous mode

Hand Claude a time budget and walk away:

```
/hwip-auto 2h fix the flaky tests
```

Claude loops explore → plan → implement → verify → commit until the budget runs out, committing each verified unit on a work branch. Questions arrive on your phone as `hwip_ask` buttons **with a stated default** — answer to steer, or ignore and the run proceeds on the safe default after the timeout. Irreversible actions (push, deploy, delete) never happen on a timeout; they wait for an explicit tap. The run ends with a report of what was committed, skipped, and auto-defaulted — plus buttons to extend, review, or finish.

Duration takes `2h`, `90m`, `1h30m`, or plain minutes (default `1h`). `/hwip-mode` shows the remaining budget mid-run.

---

## Mute & Push Mode

Pushes fire for **every** Claude Code session, not only ones launched with `hwip cc` — `hwip cc` is the remote-control bridge, not the notification switch. Silence or dial the volume, per project:

```
/hwip-mode            Show current state (mute + push mode, where it came from, last failed push)
/hwip-mode mute       Disable all notifications for this project
/hwip-mode unmute     Re-enable them

/hwip-mode quiet      Only high-priority pushes, plus completions while you're away  ← the default
/hwip-mode loud       Push on every turn
/hwip-mode normal     Push on every turn that did real work, quiet on reads

/hwip-mode approve on   Hold hard-to-undo Bash commands for approval in this project
/hwip-mode approve off  Let them run as usual  ← the default
```

**Quiet is the default.** An install with no dial pushes only on high-priority signals, so a long session doesn't turn into a stream of per-turn notifications. What still reaches you: questions (the agent asking you something is never suppressed), and the completion push once you have stepped away from the terminal — no input for `HWIP_AWAY_SEC` seconds (default 300), or no tmux client attached ([details](docs/HOOKS-EXPLAINED.md)). A session you drove from your phone also gets the server's completion push after five minutes idle. If you'd rather hear about every working turn, `/hwip-mode normal` — that was the old default.

Add `--global` to any of the three dials to set the **machine-wide default** for every project that has no dial of its own. A per-project dial always outranks it, so `/hwip-mode normal` opts a single project back into per-turn pushes and `/hwip-mode normal --global` does it everywhere.

**The approval gate** (`approve on`) holds `rm -rf`, force pushes, prod deploys and destructive SQL — a short list in `hooks/gate.sh` — before they run. At the terminal (in tmux: with this session's pane on screen), Claude Code's own permission prompt asks; when you are away, in a phone-driven (REMOTE) session, or when presence can't be read, your phone gets Approve / Deny. No answer within 75 s is a Deny. It is a speed bump against accidents, not a security boundary, and it is off while the project is muted.

State lives in a file under `${XDG_STATE_HOME:-~/.local/state}/hwip`, keyed by project directory (`pushmode-default` for the global one) — it survives reboots and new sessions until you undo it. Mute silences both hooks and CLI calls and overrides any push mode; mute stays per-project by design, since a global mute could never be lifted for a single project.

---

## Other agents

`hwip install` isn't Claude-only — it detects **every** agent on your machine and configures each one (MCP server + notification hooks + a behavioral rule file in that agent's native always-on location):

```bash
npm install -g @hwip/cli
hwip install
```

| Agent | Auto notify | MCP tools | How |
|-------|:-----------:|:---------:|-----|
| Claude Code | ✓ Stop hook | ✓ | Plugin |
| Cursor | ✓ stop hook | ✓ | MCP + hook + rules |
| Windsurf | ✓ response hook | ✓ | MCP + hook + rules |
| Gemini CLI | ✓ AfterAgent hook | ✓ | MCP + hook |
| Codex CLI | ✓ Stop hook | — | Hook + rules |
| Copilot CLI | ✓ sessionEnd hook | — | Hook + rules |
| Cline | LLM-based | — | Rules file |
| Aider | LLM-based | — | Conventions file |

**Headless box (no browser):** sign in on any machine with a browser, then copy the two values from its `~/.hwip/config.json`:

```bash
hwip install --key ak_... --hook hook_...
```

<details>
<summary><b>Manual MCP setup</b> (if you'd rather not run the installer)</summary>

**Gemini CLI:**
```bash
gemini mcp add -s user hwip hwip -- mcp
```

**Cursor** — add to `~/.cursor/mcp.json` (Windsurf: `~/.codeium/windsurf/mcp_config.json`, same shape):
```json
{
  "mcpServers": {
    "hwip": {
      "command": "hwip",
      "args": ["mcp"],
      "env": { "HWIP_API_KEY": "ak_..." }
    }
  }
}
```

`hwip mcp` runs the MCP server inside the `@hwip/cli` process. The older
`"command": "npx"`, `"args": ["-y", "@hwip/mcp-server"]` form still works, but
leaves an `npm exec` launcher resident beside the server for as long as the
session lives. `hwip mcp` needs a `@hwip/cli` new enough to have the
subcommand — `hwip help` lists it, and `hwip verify` reports which form each of
your agents is currently registered with.
</details>

---

## How it works

Hwip is three cooperating layers. Hooks fire whether or not the model cooperates; MCP tools give the model a way to reach you on purpose.

```
hwipit/plugin (Claude Code plugin)
  ├─ hooks/hwip-setup.js   → SessionStart: inject the behavioral rules
  ├─ hooks/hwip-stop.sh    → Stop: auto completion push
  ├─ hooks/hwip-ask.sh     → PreToolUse(AskUserQuestion): question push
  ├─ hooks/hwip-approve.sh → PreToolUse(Bash): opt-in phone approval for hard-to-undo commands
  ├─ hooks/hwip-remote.sh  → UserPromptSubmit: phone-sent message → REMOTE mode
  ├─ hooks/hwip-herdr.sh   → agent state → herdr sidebar, for a `hwip cc` pane
  ├─ .mcp.json             → registers the MCP server (`hwip mcp`, or `npx -y @hwip/cli mcp`
  │                          when `hwip` is not on PATH); `HWIP_API_KEY` is optional
  │                          (`${HWIP_API_KEY:-}` — unset, the key comes from ~/.hwip/config.json)
  └─ builds on:
      ├─ @hwip/cli         → hooks + notify/list/dismiss + tmux remote control
      └─ @hwip/mcp-server  → hwip_ask / notify / clipboard / file …
```

| Layer | Package | Role | Reliability |
|-------|---------|------|-------------|
| **Hooks** | `@hwip/cli` | auto-fire on Claude events | 100% — no AI cooperation needed |
| **MCP server** | `@hwip/mcp-server` | AI-callable tools (ask, notify, file…) | depends on the model following rules |
| **Plugin** | `hwipit/plugin` | bundles hooks + MCP + rules | installed once |

<details>
<summary><b>Session flow & the Ask Loop</b></summary>

```
SessionStart hook
  ├─ read ~/.hwip/config.json + the project's state files
  ├─ muted            → three lines: hooks are silent, don't call the tools
  ├─ HOOK_ID absent   → notify-only rules
  ├─ REMOTE live      → the sticky-REMOTE contract in full, no Push Signal
  └─ otherwise        → NORMAL rules, Push Signal matching the project's dial

Working…
  ├─ NORMAL (at the terminal)
  │    ├─ Question       → AskUserQuestion picker + Ask hook push
  │    └─ Task complete  → Stop hook push only (per your dial)
  └─ REMOTE (entered by a message from your phone)
       ├─ Every response → hwip_ask → button or text reply from mobile → continue
       ├─ Question       → hwip_ask (the picker is denied)
       └─ tap "Done" / type at the terminal → back to NORMAL
```

Once a session is in REMOTE, Claude uses `hwip_ask` as its final action on every response. At the terminal (NORMAL) it owes nothing — questions open the local picker and completion is just the Stop-hook push, so a session you are watching never blocks waiting for a phone tap. Your reply is treated as a direct instruction — executed without re-confirming — then Claude asks again. The loop also starts **from the phone**: send a message via the app's agent chat and the `hwip listener` records exactly what it injected; the plugin's UserPromptSubmit hook verifies the match and Claude knows you're remote ([ADR-0002](docs/adr/0002-remote-origin-detect.md)).
</details>

<details>
<summary><b>AskUserQuestion vs <code>hwip_ask</code></b> — why the local picker is the worse remote channel</summary>

Claude Code's `AskUserQuestion` is a **local blocking picker**: it renders in the terminal and waits for arrow keys. The phone can reach it, but only through the terminal mirror, and that path is worse on every axis:

- it needs the session to be running in tmux under `hwip listener` — no tmux, no mirror at all;
- it asks you to read an ANSI pane on a phone screen and count arrow presses instead of tapping a labelled button;
- the answer arrives as injected keystrokes, so the server never sees a `hwip_ask` reply and the session never enters REMOTE — meaning the *next* turn stops being phone-driveable.

`hwip_ask` needs no tmux, takes one tap, and returns an `actionId` the model can branch on. So CORE_RULES Rule 10 tells the model to route any button-friendly question through `hwip_ask`.

**Everything above applies only while sticky REMOTE is live** — and that goes for the rule as well as the hook. A hook id says you *can* drive from your phone, not that you are. In NORMAL the picker is the right tool, it opens exactly as it always did, and you still get the Ask-hook push telling you a question is waiting. Once a session is actually being driven remotely, a push-shaped question (short stem, short option labels, no `preview` block) is denied and handed back to the model to re-ask through `hwip_ask`. Long questions, long option text, and options carrying a `preview` still open the picker — those are answers the push body cannot hold. A repeat of the same denied question is let through too, so a session can never be trapped when the MCP server is unreachable.

</details>

<details>
<summary><b>Notification matrix</b> — who fires what, and can it double up</summary>

| Event | Source | Reliability | Duplicates |
|-------|--------|-------------|------------|
| Task completed | Stop hook | 100% | No (skipped if AI already sent `hwip_ask`) |
| Question asked | Ask hook | 100% | No |
| Decision / input needed | `hwip_ask` | ~80% (AI must call it) | No |
| Manual push | `hwip_notify` | on request | No |
</details>

---

## CLI reference

```bash
hwip <command>       # or: npx @hwip/cli <command>
```

| Command | Description |
|---------|-------------|
| `install` | one-command setup for every detected agent |
| `login` | browser sign-in — refresh credentials into `~/.hwip/config.json` |
| `notify --title "…" --body "…"` | send a push |
| `list [--limit 5] [--type note]` | list recent pushes |
| `dismiss <id>` · `--all` | mark pushes read |
| `cc` · `codex` · `gemini` | run the agent in a phone-reachable tmux session |
| `ask-context [status\|on\|off] [--global]` | whether a sealed question carries this project's diff and screen (see Encryption) |
| `file-view [status\|on\|off\|log] [--global]` | the switch for the phone browsing this computer's session files — on unless turned off; `off` for the current project, `off --global` for all, `on` to undo; `log` prints the last 50 reads |
| `test` | verify connection |

**Session commands (Claude Code):** `/hwip-config` (guided setup) · `/hwip-auto [duration] [task]` · `/hwip-mode [quiet|normal|loud|mute|unmute] [--global]`.

Full CLI, SDK, and listener docs: [`@hwip/cli`](https://github.com/hwipit/cli).

---

## Encryption

End-to-end encryption is **always on**: there is no switch, in the app or on this machine, and nothing to configure. Pushes, questions and their answers, and messages to another agent session leave this machine sealed, on every plan. `hwip_clipboard` and a push to a channel's subscribers (`hwip_broadcast`) are not sealed.

**Nothing falls back to plaintext.** A push needs an app to read it: when no iPhone or Android app is signed in to the account, nothing is sent and the error says to sign in to the Hwip app on an iPhone or Android phone. When an app is signed in but a send cannot be sealed — this machine's keys do not load, the device list does not load, no device lists a key, sealing fails — nothing is sent either, and the error says which step failed. The hooks hide `hwip notify`'s errors, so either refusal shows as `LAST PUSH:` in `/hwip-mode` and at session start — "no app is signed in — sign in to the Hwip app on an iPhone or Android phone" or "could not encrypt the push, so nothing was sent", never as an HTTP error ([`docs/HOOKS-EXPLAINED.md`](docs/HOOKS-EXPLAINED.md)).

Push bodies and attachments are encrypted with AES-256-GCM. Each machine holds its own ECDH P-256 keypair and the private half never leaves it — the backend stores public keys only and rejects a private-key upload. A push is encrypted once and its key wrapped separately for each device the account lists with a key. Every listed device is pinned on this machine (`~/.hwip/trusted-devices.json`) the first time it is seen, with no setup. A device that lists another key than the one pinned gets the new key: the pin is replaced and the push still goes. Whoever replaced it — `hwip notify` in a hook, the listener, the MCP server — keeps the change in `~/.hwip/key-changes.json` until a person is shown it: session start or `/hwip-mode` here (`Hwip: <device> changed its encryption key — the new key is trusted …`), a `hwip` command at a terminal, or the MCP server's next tool result. Each change is shown once.

**Threat model, honestly.** Against a *passive* backend — a leaked snapshot, an operator reading the table — the stored ciphertext is useless, so push contents stay private. Three things it does not do:

- **It does not stop an active operator.** Recipient public keys come from the same server, unsigned. A backend that injects a device record carrying its own key, or lists another key for a device you know, gets the message key wrapped for it — the pin is replaced and one line says so; nothing stops it. Comparing a device's fingerprint (`hwip trust`) with the one the app shows is the check, by eye, and a changed-key line is the signal to do it. The Hwip app's verified-device strict mode is not consulted by the CLI or the MCP server.
- **There is no forward secrecy.** The shared secret for a given sender/device pair is static, so compromising either private key opens every past push wrapped for that pair.
- **The ask loop is sealed both ways, with a limit.** `hwip_ask` / `hwip ask` seal the question — title, body, placeholder and button wording — for your devices, and your phone seals its answer back to the machine that asked. The server still sees each button's id and style, the input type, the timeout and which session asked; it never sees the text. The machine opens an answer only if the envelope was sealed with the key the account's device list registers for the answering device — the same unsigned list as above, so the active-operator limit applies to answers too; an answer from a device whose key changed since it was pinned opens, and the pin is replaced. A question that cannot be sealed — no app signed in, no device to seal for, keys that do not load, a device list that does not load — is not sent, and the ask ends in an error that says why. An answer to a sealed ask carries no attachments.

**A sealed question carries its session's context.** What the asking session changed (`git diff` against HEAD with new files, never a `.gitignore`d one) and the last 60 lines of its terminal go with the question, masked for secret-looking text first — best effort: a secret in a form the masking does not know stays. A short summary (files, lines, at most 20 paths) rides inside the sealed body, and the masked text itself is one attachment sealed for the same devices, which the phone fetches when you open the summary; the lock screen shows neither. The server sees that attachment the same way on every sealed question — named `file`, 64 KiB, kept 30 days like any attachment — also when there is nothing to carry, so it cannot tell whether a question had context or how much changed. Turn it off with `hwip ask-context off` for the project you are in (its repository root), `hwip ask-context off --global` for every project, `on` to undo; `HWIP_ASK_CONTEXT=0` skips it for one run. The switch is a file on your machine and never reaches the server. Details: [`@hwip/cli` → Encryption](https://github.com/hwipit/cli#encryption).

Your agent's machine holds a keypair too (`~/.hwip/device-keys.json`, shared by the CLI and the MCP server); the listener registers its public half, which is what the phone seals answers to.

---

## Uninstall

```bash
hwip uninstall              # remove Hwip from every detected agent
hwip uninstall --dry-run    # preview first
hwip uninstall --purge      # also delete ~/.hwip/config.json
```

Reverses `hwip install` everywhere — MCP entries, hooks, and rule files. It only touches Hwip's own artifacts: shared rule files keep your content, with just the `<!-- HWIP:START -->…<!-- HWIP:END -->` block stripped. Remove the Claude Code plugin with `claude plugin uninstall hwip@hwip`.

---

## Deep dives

- [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) — how the plugin, CLI, and MCP server fit together
- [docs/CORE_RULES.md](./docs/CORE_RULES.md) — the authoritative behavioral rules injected at session start
- [docs/HOOKS-EXPLAINED.md](./docs/HOOKS-EXPLAINED.md) — what each hook does and why

## License

Apache 2.0

Contributions are welcome: see [CONTRIBUTING.md](./CONTRIBUTING.md). Report security issues as described in [SECURITY.md](./SECURITY.md).
