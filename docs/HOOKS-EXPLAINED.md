# Hwip Hooks — Deep Dive

How the Claude Code hooks work, what they do, and how to debug them.

---

## Overview

The plugin installs these hooks (`.claude-plugin/plugin.json`), which fire automatically on Claude Code events:

| Hook | Event | File | Purpose |
|------|-------|------|---------|
| **SessionStart** | Session begins | hwip-setup.js | Inject behavioral rules into context |
| **PostToolUse** (Ask result) | After `hwip_ask` returns | hwip-ask-result.js | Hand rules 7·8 (handling the answer) over with the first `hwip_ask` result of a session context |
| **Stop** | Response ends | hwip-stop.sh | Send completion notification if work was done |
| **PreToolUse** (Ask) | Before AskUserQuestion | hwip-ask.sh | Send notification when Claude asks user a question |
| **PreToolUse** (Approve) | Before Bash | hwip-approve.sh | Opt-in: hold a hard-to-undo command until the user approves it from the phone |
| **UserPromptSubmit** | Prompt submitted | hwip-remote.sh | Flag phone-sent (and agent-sent) messages, and hold sticky REMOTE mode across later turns (ADR-0002) |
| **herdr** | SessionStart · UserPromptSubmit · Stop · Notification · Pre/PostToolUse · SessionEnd | hwip-herdr.sh | Report `working`/`idle`/`blocked` to [herdr](https://herdr.dev) for a `hwip cc` session — no-op outside one |

Every hook reads the session's transcript from the `transcript_path` field of
its JSON input — `~/.claude/projects/<project-slug>/<session-uuid>.jsonl`. The
debugging commands below use the newest one:

```bash
T=$(ls -t ~/.claude/projects/*/*.jsonl | head -1)
```

---

## SessionStart Hook (hwip-setup.js)

**What it does:**
- Runs once at the start of every Claude Code session
- Reads the API key and hook id (env, else `~/.hwip/config.json`) and the mute / push-mode / REMOTE state
- Injects the matching sections of `CORE_RULES.md` into the session context
- Emits JSON output (not stdout) so the rules land in Claude's context, not just the user's transcript
- When the plugin is silenced — no API key, muted, or no `jq` — also sets `systemMessage`,
  which the user sees in the Claude Code UI (`additionalContext` reaches only the model)
- Adds the CLI's last failed push to that `systemMessage` in every configured state.
  `hwip notify` writes `${XDG_STATE_HOME:-~/.local/state}/hwip/last-notify-failure.json`
  on failure and deletes it on success; the hooks discard notify's stderr, so this
  record is the only trace. `hooks/notify-failure.js` reads it (format: cli
  `src/notify-failure.ts`), and `/hwip-mode` shows it as `LAST PUSH:`. A refusal made
  before anything was sent carries no HTTP status: "no app is signed in — sign in to
  the Hwip app on an iPhone or Android phone", or "could not encrypt the push, so
  nothing was sent"
- Adds, once, each device whose encryption key changed. Whoever replaced the pin
  (the CLI, its listener, the MCP server) writes `~/.hwip/key-changes.json`
  (format: cli `src/key-changes.ts`); SessionStart and `/hwip-mode` show one
  `Hwip: <device> changed its encryption key …` line per device and delete the record,
  holding `~/.hwip/trusted-devices.lock` as the writers do (a record taken while
  one rewrites it would come back); a lock held past a second leaves it for next time

**When it runs:**
- Every time you start Claude Code (`claude` command)
- Once per session (does not re-run mid-session)

**What it injects — one branch, chosen from state the hook can already read:**

| State | Injected | Size |
|-------|----------|------|
| No API key (`HWIP_API_KEY` env or `apiKey` in `~/.hwip/config.json`) | helper message suggesting `npx @hwip/cli setup` | ~250 B |
| `/hwip-mode mute` marker for this project | three lines: hooks are silent, don't call the tools unless asked | ~220 B |
| No hook id (`HWIP_HOOK_ID` env or `hookId` in `~/.hwip/config.json`) | one-way notify discipline (`hwip_ask` does not exist) | ~1.3 KB |
| Sticky REMOTE live (`remote-active-<hash>`) | the sticky-REMOTE contract in full — Rules 1-3, 7-11, 13 (Rule 4 is subsumed by Rule 9 there) — and no Push Signal, since markers are ignored on a turn that already sent `hwip_ask` | ~7.4 KB |
| Otherwise | the NORMAL branch: notify discipline, Push Signal, and what starts REMOTE. No ask rules — every one of them is REMOTE-scoped, so a session at the terminal never blocks on a phone answer. Rules 7·8 (handling a `hwip_ask` answer) come with the first `hwip_ask` result instead ([Ask-Result Hook](#ask-result-hook-hwip-ask-resultjs)) | ~2.7–3.0 KB |

The Push Signal section follows the project's push-mode dial: on `quiet` (the
stock default) only the `high` marker does anything, so only that one is
injected; `normal`/`loud` get all three plus the heuristic.

**Why it branches at all.** Claude Code persists a hook's `additionalContext`
to a file the moment it exceeds **10,000 chars** and hands the model a
**2,000-char preview** instead (`cli.js`: `Pyt(e,t,r,n=k$d)`, `k$d=1e4`,
`hFr=2000`, measured against 2.1.234). The old unconditional block was 15,483
bytes, so everything past the first 2 KB — the whole Ask Loop, sticky REMOTE,
the AskUserQuestion override — never reached the model. `tests/test-hwip-setup.sh`
asserts every branch stays under that ceiling.

Any state read that fails resolves to the NORMAL branch, never back to
"emit everything".

**Example output:**

```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "# Hwip — Notification Rules (active every response)\n\n## NORMAL — the user is at the terminal\n\n...\n[the branch's sections from CORE_RULES.md]\n\nMode: two-way (notify + ask)"
  }
}
```

**Debugging:**

Check if rules are injected:
```bash
# Look at the end of your first Claude response — the rules should appear
# in the system context (not user-visible unless you ask)
grep -c "Hwip — Notification Rules" "$T"
```

If rules are missing:
```bash
# Verify CORE_RULES.md exists and is readable
ls -la /path/to/plugin/docs/CORE_RULES.md

# Check if config file is readable
ls -la ~/.hwip/config.json
echo $HWIP_API_KEY
```

---

## Ask-Result Hook (hwip-ask-result.js)

**What it does:** hands rules 7·8 ("Handling the response" in `CORE_RULES.md`)
to the model with the first `hwip_ask` result of a session context. Those rules
only govern what to do with a `hwip_ask` answer, so the NORMAL SessionStart
text leaves them out, and a session that never calls `hwip_ask` never pays for them.

**When it runs:** PostToolUse, matcher `^mcp__.*__hwip_ask$` (the plugin's
`mcp__plugin_hwip_hwip__hwip_ask` and a standalone `mcp__hwip__hwip_ask`).
Claude Code attaches the hook's `additionalContext` to the tool result. When
the call outlives 120 s and moves to the background, Claude Code attaches it to
the background-move result instead, so the rules land before the answer either way
(probed against Claude Code 2.1.310, interactive and `-p`).

**Once per session context.** The mark `handling-injected-<session_id>` sits
beside `remote-injected-<session_id>`:

- Every SessionStart (startup, resume, clear, compact) removes it.
- SessionStart writes it (content `session-start`) when it ships the REMOTE
  contract, which carries rules 7·8 already. That mark holds until the next start.
- This hook writes it (content `ask`) after the rules went out. That mark holds
  for 30 minutes. `/rewind` or a conversation restore can drop the result that
  carried the rules, and no SessionStart fires to say so. The bound keeps such a
  session at most half an hour from getting them again.
- A subagent's call (hook input with `agent_id`) neither reads nor writes it. The
  rules land in the subagent's context, so the main context's next `hwip_ask`
  still gets them.

It fails open. With no readable `session_id`, or a mark that cannot be written,
it injects every time. It writes the mark only after the output went out. With an
unreadable `CORE_RULES.md`, or no "Handling the response" heading, it injects
nothing, since there is no text to hand over. It leaves no mark and says why on
stderr, like SessionStart does.

The hook reads its input blocking (`tty.isatty`, not `process.stdin`) and whole,
because Claude Code always pipes and closes it. `hwip-setup.js` keeps its
non-blocking read, because `scripts/hwip-mode.sh` runs it with the caller's stdin.

---

## Stop Hook (hwip-stop.sh)

**What it does:**
- Fires after every Claude Code response
- Decides whether to push using a layered gate (most-specific first):
  1. **Muted** (`/hwip-mode mute`) → always silent
  2. **Push mode** (user dial): `/hwip-mode quiet` (default) → push only on a `high`
     marker, or when the user is away from the terminal (see **Away detection**
     below); `/hwip-mode loud` → push every turn; `/hwip-mode normal` → fall through.
     Read from this project's dial file, else the machine-wide default written
     by `--global` (e.g. `/hwip-mode quiet --global`), else quiet
  3. **Push Signal marker** the model may emit in its response —
     `<!-- hwip: skip -->` suppress, `<!-- hwip: push -->` force, `<!-- hwip: high -->`
     force + high priority (the marker is stripped from the push body)
  4. **Volume heuristic** (no marker): push only if ≥ 2 tool calls AND not all
     read-only (Read/Grep/Glob); otherwise stay silent (avoids exploration spam)
- Skips notification if the response already sent a `hwip_ask`
  (that already notified — no double-push; a `push`/`high` marker can't override this)

**Away detection (quiet only):**

Quiet silences routine pushes because the user is watching the pane. When
they have walked away, nobody is, so the hook still sends the completion push
(normal priority; `skip` and the read-only floor don't apply, since for an away
user the turn ending is itself the news). `hwip_is_away` in `hooks/gate.sh`
decides, and runs only on a quiet turn with no `high` marker (~30 ms). Away is
either the machine reading below, or **this session's tmux pane being hidden**
(4 below). The machine reading checks three signals, and the first that answers wins:

1. Inside tmux with **no client attached to the server** → away. If any client
   is attached, someone is at a tmux terminal, so switching sessions doesn't
   make the machine read as away (4 still asks about this session).
2. Not over SSH and `ioreg` reports **`HIDIdleTime`** (macOS system-wide
   input idle) → that alone decides. Inside tmux, "over SSH" is read from the
   session environment (`tmux show-environment SSH_CONNECTION`), which tmux
   refreshes on each attach; the process's own `SSH_CONNECTION` dates from
   server start. tmux only sees keys typed into tmux,
   so it would call a user reading a browser idle.
3. Inside tmux → the newest **`client_activity`** across clients (covers SSH
   and non-macOS hosts).
4. Beyond the machine: a keyboard or a tmux client says you are at the desk, not
   which tmux session you are looking at. Inside tmux the hook also asks about
   this session's own pane (`hwip_pane_visible`, from `$TMUX_PANE`): a session
   with no client attached, in a window that is not showing, or under another
   pane's zoom is away, even while you type elsewhere. Same limits as the
   approval gate below: a tmux that will not answer, no `$TMUX_PANE`, and any
   control-mode client (iTerm2 `tmux -CC`) leave the machine verdict alone, and
   a window linked into several sessions is not detected.

Anything unreadable counts as present. **That includes a probe the time budget
cuts** (see **Time budget** below): a slow tmux that has not said "away" by then reads
as present, so quiet stays silent. The threshold is `HWIP_AWAY_SEC`
(default `300`, `0` turns detection off — the pane check included — and a non-number falls back to
the default). Set it in the environment the agent runs in. The same probe
runs in `hwip notify --auto` (`cli/src/presence.ts`) for the other agents' hooks.

**Time budget:**

`plugin.json` gives the Stop hook 10 s, and Claude Code kills it at the cap, push
included. Each probe was bounded on its own (2 s), but a tmux that answered every call
just inside its bound cost 7.4 s per `hwip_is_away` and ~15 s through the hook's two
calls. The hook now runs on two deadlines, both readings of bash's `$SECONDS` (whole
wall-clock seconds, so off by up to one):

| What | Deadline | Ends before |
|------|----------|-------------|
| Presence probes (`tmux`, `ioreg`) | start only while < 4 s have passed; each gets `min(2 s, what is left)` | ~5 s |
| Push CLI (`hwip notify`) | gets what is left of 8 s (at least 1 s), not a flat 8 s | ~9 s |

The presence probe also runs once per hook run: its answer is kept, so the late-marker
re-gate does not ask a spent clock again.

**At the deadline the hook reads present: no push.** A probe the deadline skips or cuts
answers nothing, exactly like a tmux that never answers, and an unreadable signal never
adds a push (the same rule as everywhere above). The price is a completion push lost
for an away user whose tmux is too slow to say so within 4 s; an answer that arrived in
time (e.g. "no client attached" from the first probe) still counts and still pushes.
The control-mode check in `hwip_pane_visible` follows the same rule: skipped by the
deadline, or timing out while the Stop hook runs, it reads unknown, not hidden. The approval hook sets no deadline and keeps
the per-call 2 s bounds.

Measured 2026-10-04, stub tmux on macOS (`tests/test-hwip-stop-deadline.sh`):

| Case | Before | After |
|------|--------|-------|
| tmux answers each call in 1.8 s, hidden pane | 14.8 s, push | 3.8 s, no push (deadline) |
| tmux never answers (sleeps 30 s) | 4.2 s, no push | 4.1 s, no push |
| first probe says away after 1.8 s, push CLI hangs | 11.9 s | 8.1 s, push sent |
| first probe says away after 1.8 s, CLI fine | 3.9 s, push | 2.1 s, push |
| tmux answers instantly, hidden pane | push | push |

**When it runs:**
- After every response Claude makes
- But also after sub-agent sessions (Task tool) and observer sessions (claude-mem)

**Filtering logic:**

The hook is smart about WHAT to count:

1. **Project scope**: Only looks at the main interactive transcript
   - Skips sub-agent transcripts (`*/subagents/*`)
   - Skips claude-mem observer sessions (`*-claude-mem-observer-sessions/*`) —
     only that directory, so a project of yours named `observer` still pushes
   - Result: Only notifies when the USER's main turn ends, not internal tool calls

2. **Tool call scope**: Counts from the last REAL user message
   - "Real user message" = user typed something (string content)
   - NOT a tool_result (array of blocks, no text)
   - Result: Counts only work done SINCE the user's last input

3. **Mute check**: Skips if project is muted
   - Checks for `${XDG_STATE_HOME:-~/.local/state}/hwip/muted-{hash}` (legacy
     `/tmp/hwip-muted-{hash}` still honored when owned by the current user)
   - Hash = `cksum(project-dir)`
   - Result: `/hwip-mode mute` command silences notifications

4. **Final-text wait**: Claude Code fires Stop a beat before it flushes the
   turn's final text, and a turn that wrote text between tool calls already has
   some. The hook re-reads the transcript tail until the turn's last message is
   assistant text — up to 0.45 s for the Push Signal marker, then up to 1 s more
   once a push is committed — and uses the latest text if that runs out. Text
   that settles during the second wait is read for markers too: a late `skip`
   cancels the push, a late `high` raises it, a late `exit` clears REMOTE

5. **Bounded reads**: every transcript read is the last 2000 lines **and** at
   most 8 MiB (a window cut mid-line drops its first line, so jq never sees a
   half entry). Quiet at the terminal — the common case, and silent unless a
   marker says otherwise — first reads only the last 40 lines / 256 KiB: a
   settled final text with no `hwip:` marker, for a user who is present, ends
   the hook there. A marker, an unflushed turn or an away user takes the full
   path above, so the verdict is the same either way. A window that can never
   settle (the final line over 256 KiB) only costs the 0.45 s wait

**Example execution flow:**

```
User types: "build and commit"
  ↓
Claude runs: [call tool 1] [call tool 2] → response "Built and committed."
  ↓
Stop hook fires:
  1. Check mute file → not muted ✓
  2. Check push mode → normal (`/hwip-mode normal` set for this project) ✓
  3. Check jq installed → yes ✓
  4. Read transcript; find last real user message (index N)
  5. Count hwip_ask calls → 0 (no duplicate) ✓
  6. Read the Push Signal marker → none
  7. Count tool_use from index N → 2 tools, ≥1 non-read-only ✓
  8. Run: `hwip notify --title="Claude: myapp" --body="Built and committed." --type=hook --session=<uuid>`
  ↓
User gets push on phone: "Claude: myapp" / "Built and committed."
```

**Debugging:**

Check if tool count is correct:
```bash
# Manually count tool_use entries in your transcript
tail -20 "$T" | grep -o '"type":"tool_use"' | wc -l

# Should be ≥ 2 for a notification to fire
```

Check if jq is installed:
```bash
command -v jq && echo "✓ jq installed" || echo "✗ jq missing (install: brew install jq)"
```

Check if mute file exists:
```bash
HASH=$(printf '%s' "$(pwd)" | cksum | cut -d' ' -f1)
ls -la "${XDG_STATE_HOME:-$HOME/.local/state}/hwip/muted-$HASH"

# If file exists, notifications are silenced. Remove to unmute:
# rm "${XDG_STATE_HOME:-$HOME/.local/state}/hwip/muted-$HASH"
```

Test the hook manually:
```bash
# Simulate what the hook does (count tools since last real user message)
jq -c 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use") | .name' \
  "$T" | tail -5
```

**Why sometimes silent:**
- Tool count < 2, or all tools were read-only (Read/Grep/Glob), with no marker
- The response emitted a `<!-- hwip: skip -->` Push Signal
- Push mode is `/hwip-mode quiet` and the turn had no `high` marker — set for this
  project, or inherited from a `/hwip-mode quiet --global` default (`/hwip-mode`
  says which)
- jq not installed (hook exits early)
- Project is muted (`/hwip-mode mute` was run)
- Mute file still exists (stale from previous session)
- Response already sent a `hwip_ask` (Stop hook deduplicates)

---

## Ask Hook (hwip-ask.sh)

**What it does:**
- Fires when Claude calls `AskUserQuestion` tool
- Extracts the question text from the tool call
- Sends it as a push notification via the CLI
- User answers at the terminal — or from the phone's terminal mirror (↑/↓ then
  Enter), when the session runs in tmux under `hwip listener`. The push itself is
  one-way; the mirror is what carries an answer back, and the hook says which of
  the two the user actually has.

**When it runs:**
- Only when Claude explicitly calls `AskUserQuestion`
- Not automatic (depends on Claude's behavior)

**Example flow:**

```
Claude thinks: "I need to ask the user to choose between A and B"
  ↓
Claude calls: AskUserQuestion({ prompt: "Choose A or B?" })
  ↓
PreToolUse hook fires (before the tool actually executes):
  1. Extract the question: "Choose A or B?"
  2. Run: `hwip notify --title="Claude asks: myapp" --body="Choose A or B?" --priority=high`
  ↓
User gets push on phone
  ↓
User switches to terminal and answers the question locally
```

**Debugging:**

Check if tool was called:
```bash
# Look for AskUserQuestion in the transcript
grep -c "AskUserQuestion" "$T"
```

Check the notification was sent:
```bash
# List recent pushes
hwip list --limit 5
```

Check for errors:
```bash
# If the hook silently failed, check:
# 1. Is hwip CLI installed? 
command -v hwip || echo "npx -y @hwip/cli" 

# 2. Is HWIP_API_KEY set?
echo $HWIP_API_KEY

# 3. Is the project muted?
HASH=$(printf '%s' "$(pwd)" | cksum | cut -d' ' -f1)
ls "${XDG_STATE_HOME:-$HOME/.local/state}/hwip/muted-$HASH"
```

---

## Approve Hook (hwip-approve.sh)

**What it does:** holds a hard-to-undo Bash command (`rm -rf`, force push, prod
deploy — the short list in `gate.sh` `hwip_approve_needed`) until the user taps
Approve on the phone. A speed bump against accidents, not a security boundary:
it matches text in the command string.

**When it runs:**
- Before every Bash tool call, but only does anything in a project that opted
  in with `/hwip-mode approve on` — it creates
  `${XDG_STATE_HOME:-~/.local/state}/hwip/approve-<hash>` (same `cksum` hash as
  the mute file); `/hwip-mode approve off` removes it
- Never while the project is muted: no push can reach the user, so there is no
  one to ask

**At the terminal:** when `hwip_presence` (gate.sh — the same probes the quiet
dial uses) reads `present`, the session is not in REMOTE, and the hook input's
`permission_mode` is `default`, `acceptEdits` or `plan`, the hook answers `ask`
and Claude Code's own permission prompt holds the command — no phone, no 75 s
wait. `ask` is never an allow. Anything else — away, presence unreadable,
REMOTE, a bypass-style mode, no mode — goes to the phone. Presence is the
machine's, so inside tmux the hook also asks about this session's own pane
(`hwip_pane_visible`, from `$TMUX_PANE`): a session with no client attached, in
a window that is not showing, or under another pane's zoom keeps the phone. A
pane that is on screen in a terminal you are not looking at still reads as
watched, a tmux that will not answer leaves the machine verdict alone, and so
does any control-mode client (iTerm2 `tmux -CC` shows non-current windows as
tabs). A window linked into several sessions is not detected. The quiet
dial's `away` check asks the same question (see **Away detection**).

**Flow (phone):** `hwip ask --title="Approve in <project>?" --body="<command>"` with
Approve / Deny buttons. The hooks pass every flag value as one `--flag=value` word: the
command (and the model's message in the Stop hook) is untrusted text, and as a separate
word one that began with `--base-url=…` would be read as a flag of the CLI itself. A NUL byte in the command
cannot live in a shell variable, so the approval body shows it as `␀` (U+2400) rather than dropping it. Approve → `allow`. Deny, timeout, unreachable server or
free text → `deny`, with a reason that says which — `hwip ask`'s `reason`
tells a cancel on the phone (don't retry) from a timeout or an error. Claude Code lets the tool
call run when a hook times out, so the hook answers well inside its own 120 s
limit — late is a refusal, never a pass.

---

## Remote-Origin Hook (hwip-remote.sh)

**What it does (ADR-0002):** two jobs — entering REMOTE, and leaving it.

*Entry:*
- Fires on every prompt submit, and enters REMOTE only when the prompt matches
  a marker the `hwip listener` wrote as it injected a phone message into this
  project's tmux pane — or a message another agent sent with `hwip_agent_send` /
  `hwip agent send`, which the listener injects the same way (ADR-0002 amendment
  2026-09-25)
- Match = same project (cksum of dir) + fresh (≤15 min) + byte-identical
  sha256 of the trimmed text — a terminal keystroke can never false-match
- On match: consumes the marker (one-shot), records the mode in the state file
  below, and injects context telling the model the user is remote → sticky
  REMOTE mode (every response ends with an answerable `hwip_ask`)
- Without a hook id: one-way variant — tells the model to make the
  Stop-hook push self-contained and mention `npx @hwip/cli setup` once. No
  state is recorded: without `hwip_ask` there is no mode to stay in. The hook
  id is `HWIP_HOOK_ID` when set to a real value (an unresolved `${…}`
  placeholder counts as unset), else `hookId` in `~/.hwip/config.json`. One
  contract, mirrored per runtime: gate.sh `hwip_hook_id` (shell hooks),
  hwip-setup.js `envOr` (SessionStart), cli `config.ts`, mcp-server
  `config.ts` — each with its own tests

*Leaving:*
- The marker is one-shot, but REMOTE is not — it lives in the state file below,
  which is also what makes it survive context compaction (Rule 13)
- A prompt that reaches this hook without a marker was typed at the terminal,
  so the hook clears the state and says once that the session has left REMOTE;
  later terminal turns then cost nothing
- Exception: turns Claude Code writes itself — `<task-notification>` (a
  background task or MCP call finished), a subagent or peer report (`Another
  Claude session sent a message…`, `A peer session sent a message…`,
  `<cross-session-message`), or a plugin-submitted prompt (`The <name> plugin
  sent a message…`). They reach UserPromptSubmit with no marker, and the hook
  input carries no origin field, so `system_turn` matches the prompt prefix and
  leaves the mode alone. It matters because a `hwip_ask`
  can arrive this way: past Claude Code's MCP auto-background window (120 s by
  default, `CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS`), or when another message lands
  while it waits, the call moves to the background and the phone answer comes
  back as a task notification instead of a `tool_result`
- Exception: a *fresh* marker the prompt failed to match means a phone message
  is still in flight (queued behind a long turn, or a digest the two sides
  compute differently). The evidence is ambiguous, so the hook says nothing and
  leaves the mode alone rather than stranding a user who is still on the phone.
  A stale or unparseable marker can never match and reads as a terminal turn
- Re-entry is one phone message: the next injection writes a fresh marker
- Mute still outranks both jobs, and neither ever blocks a prompt (always
  exit 0, including on state-file IO failure)

**Marker file** — entry signal, written by cli `listener.ts`, consumed here:

```
${XDG_STATE_HOME:-$HOME/.local/state}/hwip/remote-<hash>
content: "<epochSeconds> <sha256hex-of-trimmed-text>\n"
```

**State file** — the mode itself, written, read and cleared here (`gate.sh`
`hwip_remote_active` / `hwip_remote_touch` / `hwip_remote_clear`; TS twin
`cli/src/gate.ts`):

```
${XDG_STATE_HOME:-$HOME/.local/state}/hwip/remote-active-<hash>
content: "<epochSeconds it was last confirmed>\n"
```

Every phone prompt or answered `hwip_ask` refreshes it, and it expires 4 hours
after that last refresh. The TTL is the backstop, not the usual exit — a
terminal-typed prompt, a Done-like answer and the model's `<!-- hwip: exit -->`
all delete the file outright. What none of them covers is a session that
crashed: no SessionEnd hook clears this file (the herdr hook uses SessionEnd for
its own state, not this one), so without the TTL a Ctrl-C would leave
REMOTE latched and later sessions in this project would keep asking an absent
phone.

The hooks read that number through `hwip_age_sec` (hooks/gate.sh), which takes a
plain number of at most 12 digits, reads a leading 0 as decimal (bash arithmetic
would call it octal, and the error ends the command it sits in, so the REMOTE
check is skipped), and treats a time ahead of the clock as now. For `remote-active-<hash>` a future time is also written back as now, so the
TTL counts from the moment it was seen; any other value is dropped as damage.
The phone-origin marker reads a future time as now; the denied-question stamps drop it.

**The full contract goes to a session once.** Rule 9 in full is ~2.7 KB, and
the hook used to attach it to every phone message. A `remote-injected-<session_id>`
file in the same state dir (empty; `session_id` from the hook input, accepted
only as `[A-Za-z0-9_-]`) records that a session holds the text. The first phone
message of an unmarked session gets the full text and writes the mark; later
ones get a short reminder (the `hwip_ask` duty with actions, a Done-like
fallback and a 300–600 s timeout, plus the exits). It is per session, not per
project: `remote-active-<hash>` is keyed by the directory, so a second session
in the same directory finds a live REMOTE it was never told about and still
gets the full text. SessionStart (every source — startup, resume, clear,
compact) removes the mark, since a fresh or compacted context has lost the
text, and writes it only when it ships the REMOTE contract itself; it also
prunes marks untouched for a week, and with no readable `session_id` it drops
every mark (none can be addressed). A start whose Rule 9 section cannot be read
marks nothing. No `session_id` in the input → never marked, always the full
text. Accepted limit (unverified): `/rewind` may restore the conversation without
firing SessionStart, which would leave a mark for text that is no longer in
context — the next phone message then gets only the reminder.

**Example flow:**

```
User (on phone) sends "fix the login bug" via agent chat
  ↓
listener injects into tmux pane + writes remote-<hash> marker
  ↓
Claude Code submits the prompt → UserPromptSubmit hook fires:
  1. marker exists, fresh, sha256 matches → rm marker
  2. write remote-active-<hash>
  3. emit additionalContext: "user is remote → sticky REMOTE mode"
  ↓
Claude does the work, ends the response with hwip_ask
  ↓
User answers with a button tap — the loop continues from the phone
  ↓
...later the user types at the terminal instead. No marker, so they are
back at the keyboard: the hook rm's remote-active-<hash> and emits once
  "left sticky REMOTE mode — answer normally (Rule 4)"
  ↓
Every later terminal turn: no marker, no state → silent no-op
  ↓
The user picks the phone back up and sends another message → new marker,
REMOTE again
```

**Debugging:**

```bash
# Is a marker present for this project?
HASH=$(printf '%s' "$(pwd)" | cksum | cut -d' ' -f1)
cat "${XDG_STATE_HOME:-$HOME/.local/state}/hwip/remote-$HASH"

# Verify what the hook would compute for a given prompt
printf '%s' "fix the login bug" | shasum -a 256

# Requires the cli listener new enough to write markers (release order:
# cli ships first) and jq on PATH; without either the hook no-ops.
```

---

## herdr Hook (hwip-herdr.sh)

**Why.** herdr finds agents by a pane's foreground process. In a `hwip cc` pane that
is the tmux client — Claude Code runs under the tmux server — so the agent never
showed in herdr's sidebar. The hook reports the state itself through herdr's
report API (`herdr pane report-agent`), labelled `hwip cc`. herdr ignores a report
labelled `claude`, the name of an agent it supports natively (measured on herdr 0.9.3).

**Which pane.** The CLI wrapper (`@hwip/cli`) records the herdr pane on every attach
as tmux session options — `@hwip_herdr_pane`, `@hwip_herdr_socket`,
`@hwip_herdr_bin` (the values of `HERDR_PANE_ID`, `HERDR_SOCKET_PATH`,
`HERDR_BIN_PATH`) — and clears them on an attach from outside herdr. The hook reads
them with one `tmux display-message`, one value per line: `display-message -p` prints
any other control character as a literal octal escape (`\x1f` -> `\037`, tmux 3.5a). No options means no herdr, so the hook does
nothing, including for plain `claude` in a herdr pane, which herdr detects on its
own, and for a CLI that does not write the options yet. It also no-ops for a
headless `claude -p` (`CLAUDE_CODE_ENTRYPOINT=sdk-cli`): one started from a shell in
the pane inherits `TMUX_PANE`, and its SessionEnd would otherwise release the pane's
real agent.

| Event | State |
|-------|-------|
| SessionStart | `idle` (claims the pane); nothing when it fires for a compaction (`source: compact`) |
| UserPromptSubmit | `working` |
| Notification `permission_prompt` / `elicitation_dialog`, PreToolUse `AskUserQuestion` | `blocked` |
| PostToolUse | `working`, only if the last report was `blocked` |
| Stop, Notification `idle_prompt` | `idle` |
| SessionEnd | release the pane |

`idle_prompt` covers an Esc interrupt, which fires no Stop: the pane reads `working`
until Claude Code's idle notification fires.

**Known gaps.** A denied permission prompt fires no PostToolUse, so the pane reads
`blocked` until the next tool call or Stop. Any other `claude` process started in
a pane of the same tmux session (an agent-team split pane, say) reads the same
options and would report to the same herdr pane, and its SessionEnd would release
it; whether such panes exist, and carry a signal to tell them apart, is unverified.

**Cost.** PostToolUse runs on every tool call, so its common case exits after
reading one state file in `$HWIP_STATE_DIR` (`herdr-<pane>`, per-user like the other state files), before any tmux call. A state equal
to the last one sent is not resent — unless herdr has restarted since, which drops every
report it held: herdr recreates its socket when it starts, so a socket newer than the
state file sends the state again (a `test -nt`, no fork, so the tool-call path stays cheap). And `herdr` runs detached (as an array, so a
`herdr` path with a space works). The one blocking call, `tmux display-message`, is
cut at 2 s by `timeout`, `gtimeout` or perl (gate.sh `hwip_bound_prefix`, the same bound
the other hooks put on their calls), well inside the hook's 5 s cap. `--seq` is
microseconds since the epoch, bumped past the last one sent, because herdr drops a
report whose seq is not above the last it accepted from the source.

---

## Full Event Timeline

Here's what happens during a typical Claude Code session:

```
TimelineEvent                            | Hook      | Output
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. $ claude (start session)              | START     | Rules injected into context
2. User types: "fix bug in X.ts"         |           | (no hook)
3. Claude responds + calls 2 tools       | STOP      | Push: "Claude: myapp" (normal dial)
4. $ (user reads push on phone)          |           | (no hook)
5. User types: "actually, also Y too"   |           | (no hook)
6. Claude calls AskUserQuestion          | ASK       | Push: "Claude asks: myapp" — deploy now?
7. (user sees phone push)                |           | (no hook)
8. User answers at terminal              |           | (no hook)
9. Claude processes answer + runs tools  | STOP      | Push: "Claude: myapp" (normal dial)
10. User types: "done" → Claude exits    | STOP      | (exit, no push — hook sees 0 tools)
```

---

## Common Issues & Fixes

| Issue | Cause | Fix |
|-------|-------|-----|
| No notifications at all | `jq` not installed | `brew install jq` (macOS) or `apt install jq` (Linux) |
| Duplicate notifications | hwip_ask was called + Stop hook fired | Claude is following rules correctly; Ask loop working |
| Notifications muted | `/hwip-mode mute` was run | Run `/hwip-mode unmute` to re-enable |
| Question notifications missing | Claude didn't call AskUserQuestion | Check: is Claude asking plainly instead? (rule violation) |
| Push title names the wrong project | `CLAUDE_PROJECT_DIR` not set, so the hooks fell back to the working directory | Run the session under Claude Code, which sets it |

---

## Testing Hooks Offline

You can test the logic without running Claude Code:

```bash
# Test hwip-stop.sh: count tools in a sample transcript
echo '{"type":"tool_use"}{"type":"tool_use"}' | jq . | grep tool_use | wc -l

# Test hwip-ask.sh: extract question from tool call
echo '{"tool_input":{"question":"Test?"}}' | jq -r '.tool_input.question'

# Test mute check
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hwip"; mkdir -p "$STATE_DIR"
HASH=$(printf '%s' "." | cksum | cut -d' ' -f1)
touch "$STATE_DIR/muted-$HASH" && echo "✓ Mute file created"
[ -f "$STATE_DIR/muted-$HASH" ] && echo "✓ Mute check works"
rm "$STATE_DIR/muted-$HASH"
```

---

## Extending Hooks

To add custom behavior (e.g., call an external API, log to file):

1. **Do NOT modify** the plugin's hook scripts directly — a plugin update overwrites them
2. **Instead**, register your own hook for the same event in your project's
   `.claude/settings.json` (or `~/.claude/settings.json`)

Plugin hooks and your hooks both fire on the event.

---

**Last updated**: 2026-10-02
**Relevant**: All Hwip users experiencing hook issues or debugging notifications
