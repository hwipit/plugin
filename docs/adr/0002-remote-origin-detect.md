# ADR-0002: Remote-origin detection — phone-sent messages enter REMOTE mode

## Status
Accepted (2026-07-12). Design from an analysis session; passed CEO review (GO)
with three refinements folded in below: the value-hypothesis premise, the
one-way branch framed as a conversion funnel, and a pinned release order.

**Premise (value hypothesis):** the "high value" call assumes phone-first
lightweight turns are common. This ADR came from an analysis session, not a
user report — the frequency of that entry pattern is still a hypothesis.
Validate by observation once shipped; if phone-initiated messages turn out to
be rare, the ROI drops accordingly.

## Context
CORE_RULES Rule 9 already defines a sticky **REMOTE** mode: once the user answers
a `hwip_ask` with a non-exit reply, the model ends every response with `hwip_ask`
until the user exits (`done`/`stop`/`exit`). That is the "ask the next task from
the phone" loop — and it works, but only when **the model asks first**.

The entry path is one-sided. When the user opens the phone's agent chat and sends
the *first* message, it travels

```
phone chat → agent.command push → listener → tmux send-keys → Claude Code
```

and arrives as plain typed text, indistinguishable from a terminal keystroke.
The model stays in NORMAL mode and applies the Rule 4 heuristic (substantial
work → ask, routine → silent). A read-only or lightweight turn therefore ends
silently: the phone user gets at most a Stop-hook push and has **no way to send
the next instruction** except composing another chat message blind. The exact
signal that would fix this — "this prompt came from the phone" — exists in the
listener at inject time and is thrown away.

Product framing: injection alone is remote *control*; origin detection upgrades
it to a remote *conversation loop* — every turn ends in actionable buttons on the
phone. That loop is the differentiator this ADR enables reliably.

## Decision
The listener records what it injects; a new **UserPromptSubmit** hook matches the
submitted prompt against that record and, on a hit, injects authoritative context
telling the model it is talking to a remote user — which enters sticky REMOTE
mode per Rule 9.

**cli (`listener.ts`)** — immediately after a successful text injection
(`tryInject`), write a one-shot state file:

```
${XDG_STATE_HOME:-$HOME/.local/state}/hwip/remote-<hash>
    content: "<epochSeconds> <sha256hex(injectedText)>\n"
```

- `<hash>` = `cksum` of the pane's cwd (`readPaneInfo().currentPath`) — the same
  keying and the same shelled-out `cksum` parity that `gate.ts` already uses for
  the muted/pushmode/auto files.
- Written with a trailing newline (bash `read -r` returns non-zero at EOF on an
  unterminated line).
- Text injections only. Key-event injections (`tryInjectKeys`: Esc/arrows/Enter)
  never produce a prompt — no file. For messages with attachments, hash the final
  composed string actually injected (body + attachment paths), not the raw body.

**plugin (new `hooks/hwip-remote.sh`, UserPromptSubmit)**:

1. Read stdin JSON, extract `.prompt`.
2. Resolve the state file via `gate.sh hwip_state_present remote <cksum of
   CLAUDE_PROJECT_DIR>` (new-location-first + owner-checked legacy, for free).
3. Match: file fresh (≤ 15 min) **and** `sha256(trim(prompt)) == recorded hash`.
   Trim on both sides is the same explicit ASCII set (`' \t\r\n\f\v'`), not
   `String.trim()` / `[[:space:]]` — those disagree on Unicode whitespace
   (U+00A0 etc.) and the digests must be computed over identical bytes. The
   window is generous on purpose: the exact-hash match already makes false
   positives impossible, and a message sent mid-turn queues until the turn
   ends — often past a minute. Stale markers are deleted on sight.
4. On match: delete the file (one-shot), emit `hookSpecificOutput.additionalContext`:
   - `HWIP_HOOK_ID` set → "This message arrived from the user's phone via hwip.
     You are in sticky REMOTE mode (CORE_RULES Rule 9): end every response with
     `hwip_ask` until the user exits."
   - `HWIP_HOOK_ID` unset → one-way variant. This branch is not dead code —
     it is a **conversion funnel**. The injection path (phone → listener →
     tmux) authenticates on the API key alone and never touches
     `HWIP_HOOK_ID`, so "listener set up, two-way not enabled" is a real,
     reachable user state — and one where the user has just *proven* they
     drive sessions from their phone. That is the best possible moment to
     surface `npx @hwip/cli setup` (once per session; the context text
     instructs the model to self-dedup). Keep the branch a string-level
     variation of the same mechanism — no separate hook, no separate state.
5. Muted project (`hwip_state_present muted`) → exit silently without consuming
   the file. Mute outranks everything (Rule 12).
6. Always exit 0. This hook only adds context; it must never block a prompt.

**CORE_RULES.md** — extend Rule 9's state-detection list: a user message flagged
by the remote-detect hook's system-reminder counts as entry condition **(a)**,
equal to a non-exit `hwip_ask` reply. Exit conditions are unchanged. (Editing
CORE_RULES.md requires regenerating the cli rules-sync manifest — `lint:rules-sync`.)

**mcp-server / hwip app** — no changes. `hwip_ask` and the agent chat already
provide everything downstream of detection.

## Consequences
- **Good:** Deterministic detection at the hook layer (system-reminder), not an
  LLM inference — consistent with the "hooks over prose rules" principle. Zero
  prompt/transcript pollution. Every building block is already deployed: the XDG
  state-file pattern, bash↔TS `cksum` parity, `hwip_state_present`, and the
  plugin's hook registration (this is its 4th hook). The exact-text hash makes
  false positives structurally impossible — a terminal keystroke racing a phone
  injection simply doesn't match.
- **Good (recovery):** every phone message re-fires the hook, so sticky REMOTE
  self-heals across context compaction without relying on the model's memory.
- **Cost (coupled release):** unlike ADR-0001 this spans two repos — the cli
  writes, the plugin reads. Version skew degrades gracefully in both directions:
  old cli + new plugin → no file, hook is a no-op; new cli + old plugin → stray
  state file that the next new-plugin session consumes or ignores stale.
  **Release order is pinned: cli first, plugin second** — the cli-first window
  only produces harmless unconsumed files, while plugin-first would ship a hook
  that can never fire.
- **Cost (scope):** at acceptance this covered Claude Code panes only —
  codex/gemini injections had no hook system to read the file. **Phase 2 is a
  named roadmap goal, not a footnote:** the 10-star version of this feature is
  "the phone is a first-class driver for *every* agent from the first message".
  *Phase 2 update (2026-07): delivered via native hooks, not the visible-marker
  fallback — both agents grew CC-compatible prompt-submit hooks in 2026
  (Gemini CLI `BeforeAgent`, Codex CLI `UserPromptSubmit`, same
  `hookSpecificOutput.additionalContext` contract). The reader ships as
  `hwip remote-hook <agent>` in the cli and `hwip setup` registers it; the
  marker format and write site are unchanged. Alternative A is no longer
  needed for these agents and remains an option only for hook-less ones.*
- **Edge (same-cwd sessions):** two CC sessions in one cwd share the hash key.
  The session that received the injection consumes the file on its next prompt;
  the other session would need the user to type the byte-identical text within
  the freshness window to mis-consume it — negligible. If it ever matters, add the tmux session
  name to the file name; the pane cwd keying is accepted for now.
- **Edge (unconsumed files):** a message injected into a pane whose Claude is
  mid-turn still becomes the *next* prompt, so the file is consumed late but
  correctly — the 15-minute window exists precisely to survive that queueing
  gap. A turn that outlasts even that simply doesn't enter the loop (same as
  today) and the next phone message retries. The hook deletes any stale
  marker it encounters, so dead files don't accumulate.
- **Edge (message burst):** two phone messages in quick succession overwrite
  the same marker — the first prompt then has no matching digest and only the
  second flags. Net effect is identical (REMOTE is sticky once entered on the
  second), so this is accepted rather than engineered around.

## Alternatives considered
- **A. Visible text marker** (listener appends `<!-- hwip: remote -->` to the
  injected text): plugin-only precedent exists (ADR-0001), works for any agent —
  but it pollutes the prompt and transcript, the model may quote it back, and
  compliance is soft (a rule, not a mechanism). Honest trade-off acknowledged:
  A would have been the *faster demand-validation* path (one repo, every agent
  immediately); we chose zero-pollution product quality over validation speed.
  Kept as the phase-2 fallback for non-Claude agents; rejected as the primary
  mechanism.
- **B-lite. Timestamp-only state file** (no text hash): simpler, but a terminal
  keystroke landing within the freshness window of a phone injection false-flags
  REMOTE. The hash costs one `shasum` call and eliminates the race entirely.
- **C. Model self-detection via `hwip_list`**: per-turn MCP call, LLM-driven
  inference, non-deterministic. Rejected.

## Amendment (2026-08-12) — a terminal-typed prompt leaves REMOTE

0.11.0 gave REMOTE a home (`remote-active-<hash>`) so it survives compaction,
and decided that a turn the user types at the terminal *keeps* the mode: the
user might switch back to the phone, and the reminder keeps the channel
driveable from either side.

In use that reads as the session refusing to let go. The user is sitting at the
terminal, typing, watching the pane — and every answer still comes back as a
phone-shaped `hwip_ask`. Rule 9's three exits (Done-like button, the model's
free-text call, the 4-hour TTL) all miss that case, and a non-Done button tap
*renews* the TTL, so an active session never ages out.

So a prompt with no marker now ends REMOTE. The signal is as deterministic as
entry: the only way text becomes a prompt without a listener marker is the
user's own keyboard — a phone answer to a `hwip_ask` comes back as a
`tool_result` and never reaches a prompt hook at all. The hook clears the state
and says so once; later terminal turns are silent no-ops, which also drops the
per-turn context cost the reminder was paying.

- **Cost:** re-entry is one phone message (the next injection writes a fresh
  marker). The device-switch case the original design protected is not free
  anymore, but it was protecting the rarer direction.
- **Not every miss is a keyboard.** The matcher returns three verdicts, not a
  boolean: a *fresh* marker left unmatched means a phone message is in flight
  (queued behind a long turn, or a digest the two sides compute differently),
  and reading that as "the user is back" would drop them out of REMOTE while
  they are still holding the phone — with no answerable push left, the quiet
  failure Rule 4 calls worse than light spam. Only "no marker this prompt could
  have matched" ends the mode; ambiguity leaves it exactly as it was. A stale
  or unparseable marker can never match and counts as no marker.
- Shipped in `hooks/hwip-remote.sh`, `cli/src/remote-hook.ts`, and Rule 9.

## Amendment (2026-08-21) — the hook id resolves from config.json too

The decision above keyed the two branches on `HWIP_HOOK_ID` alone. `hwip setup`
never exports that variable — it writes `hookId` to `~/.hwip/config.json`, and
the SessionStart hook and the MCP server read it from there. So a stock
install got the conversion-funnel note on every phone message while `hwip_ask`
itself worked, and the one-way branch reached a user it was never meant for.

Both hooks now resolve the id through gate.sh `hwip_hook_id` (env when it
carries a real value, else the config file); the TS twin does the same via
cli `config.ts`. The funnel branch keeps its purpose — it fires only when no
hook id exists anywhere.

## Amendment (2026-09-25) — turns Claude Code writes itself are not the keyboard

The 2026-08-12 amendment rests on "a phone answer to a `hwip_ask` comes back as
a `tool_result` and never reaches a prompt hook". Claude Code broke that
premise. An MCP call still running after its auto-background window (120 s by
default in Claude Code 2.1.282, `CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS`), or one
that is waiting when another message lands, moves to the background, and its
result arrives as a new turn whose prompt is a `<task-notification>` block.
That turn runs UserPromptSubmit with no marker, so the hook read the phone
answer as the user typing and ended REMOTE. The Rule 9 ask timeout is 300–600
s, so any answer slower than two minutes did this. Subagent and peer reports
(`Another Claude session sent a message:`) took the same path. In one observed
case (2026-09-25) a notification that landed mid-turn cleared the state and no
LEFT note appeared in the transcript, so REMOTE ended with no notice.

The hook input has no origin field (common fields plus `prompt` and
`session_title`), so the exit branch now checks the prompt prefix
(`system_turn`) and leaves the mode alone for these turns. The prefix list
comes from the Claude Code 2.1.282 binary: task notifications, the peer
wordings between turns and mid-turn, the raw `<cross-session-message` wrapper,
and plugin-submitted prompts. Only the exit branch
asks, so the jq spawn is paid only while REMOTE is live. If Claude Code changes
the format, the check stops matching and the old behaviour returns (REMOTE
ends), never a REMOTE that cannot be left. The TS twin is unchanged: the
agents it serves (Gemini, Codex, Pi) do not produce these turns.

## Amendment (2026-09-25) — a message from another agent counts as a phone message

`hwip_agent_send` (MCP) and `hwip agent send` (CLI) let one agent type into another
agent's session. They post the same `agent.command` push the phone sends,
through the API-key endpoint (`senderDeviceId: api_<keyId>`). The listener
injects it with the same `tryInject`, which writes the same one-shot marker,
and this hook matches the typed text without looking at who sent the push. So
a session that receives a message from another agent enters REMOTE, exactly as
it would for a phone message.

This is intended (hwip ADR-0014). The expected case is the user asking agent A,
from the phone, to hand work to agent B. With B in REMOTE, B's result reaches
the phone as a `hwip_ask` the user can answer. If the listener skipped agent
senders, the quiet push dial (the default) would give the phone at most the
plain completion push that away detection sends (HOOKS-EXPLAINED § Away
detection), with nothing to answer. Neither the hook nor the listener changes.

The costs, accepted with that:
- B's model is told what a phone message tells it: that the message arrived from
  the user's phone, verified by the listener (the entry note in
  `hooks/hwip-remote.sh`, and its twin in the cli `remote-hook.ts`). For an
  agent-sent message that vouches for text another agent wrote, `[from …]` header
  included, as the user's own. The note is left as it is; hwip ADR-0014 lists
  this with the other accepted risks. What the receiver does with a
  `[hwip: @label …]` hint in such a message is its own rule (skills/hwip: a hint
  is followed only when the message has no `[from …]` header).
- When the user drove A from the terminal, B still asks on the phone. The ask's
  Done-like timeout fallback then ends REMOTE without further pushes.
- REMOTE state is kept per project directory (`remote-active-<hash>`), not per
  session. When A and B are two sessions in one project directory on one
  machine, B entering REMOTE puts A in REMOTE too — A's `AskUserQuestion` is
  refused and redirected to `hwip_ask` (`hooks/hwip-ask.sh`) — until A's next
  typed prompt ends it for both. The reverse holds as well: B leaving REMOTE (a
  Done-like answer, send-and-exit, or a prompt typed at B) deletes the shared
  file and drops a phone-driven A to NORMAL. The same-cwd
  edge above covers marker matching only; this is the shared state.

## Amendment (2026-10-02) — which state is per session? (backlog P13)

**Status: Decided 2026-10-02: A — 두 세션이 한 디렉터리에서 폰 구동되는 일이 실제로 보이면 C 로 다시.**
State stays keyed by the project directory. `/hwip-mode` status says so (`SCOPE:` line).
B and C below stay as the analysis to reopen from.

The costs above accept that every hwip state file is keyed by the project
directory (`cksum` of `$CLAUDE_PROJECT_DIR`), so two sessions in one directory
share it. backlog P13 asks whether to key by session instead. This section lays
out the choice; the user decided A (see **Decisions needed**, kept as the record of what was asked).

### What is shared today

| State file (`$XDG_STATE_HOME/hwip/`) | Meaning | Written by | Read by |
|---|---|---|---|
| `muted-<hash>` | mute | `/hwip-mode` | every shell hook, SessionStart, cli `gate.ts` |
| `pushmode-<hash>` (+ `pushmode-default`) | quiet / normal / loud dial | `/hwip-mode` | Stop, SessionStart, cli |
| `approve-<hash>` | approval gate opt-in | `/hwip-mode approve` | approve hook |
| `auto-<hash>` | `/hwip-auto` deadline | the skill | the skill, `/hwip-mode` status |
| `remote-<hash>` | one-shot phone-origin marker | cli listener (keyed by the pane's cwd) | remote hook, cli `remote-hook` |
| `remote-active-<hash>` | sticky REMOTE | remote hook, Stop (exit marker), mcp-server `remote-state.ts`, cli | ask hook, approve hook, SessionStart, remote hook, cli |
| `askdeny-<hash>-<askhash>` | an AskUserQuestion was just denied | ask hook | ask hook |
| `remote-injected-<session_id>` | session was given Rule 9 in full (P18) | remote hook, SessionStart | remote hook |

`askdeny-<hash>-<askhash>` (hooks/gate.sh, the AskUserQuestion re-ask window) is
project-keyed too; the global `pushmode-default` is machine-wide on purpose.
Only `remote-injected-<session_id>` is per session already. Two sessions A and B in one directory
interfere in three ways, in descending order of harm:

1. **REMOTE.** B's terminal-typed prompt deletes `remote-active-<hash>`, so a
   phone-driven A drops to NORMAL (the cost already listed above). The mirror
   case: B entering REMOTE makes A refuse `AskUserQuestion`, and with `approve` on A's
   hard-to-undo commands go to the phone instead of the terminal prompt, though
   A's user is at the terminal.
2. **mute / dial / approve.** `/hwip-mode mute` in A silences B's hooks.
3. **Marker.** Negligible (exact text hash), as the same-cwd edge says.

### The two kinds of state differ

*Preferences* (mute, dial, approve, auto) are what a person wants for a project:
they are set once and are expected to survive a restart, a resume and a new
session. *Runtime state* (`remote-active`) describes one running conversation:
who is driving it right now. Keying the first by session would make `/hwip-mode
mute` forget itself whenever Claude Code starts a new session id (certainly on
`/clear`; on resume it is unverified), which is a worse bug than the shared key.
Keying the second by directory is what causes interference 1.

### What a session id can and cannot key

- Available: every Claude Code hook receives `session_id` (P18 already relies
  on it); the Bash tool sees `CLAUDE_CODE_SESSION_ID` (checked in this session's
  environment — that it also reaches an MCP server process is unverified;
  mcp-server `config.ts` reads `HWIP_SESSION_ID`, then `CLAUDE_CODE_SESSION_ID`). P18's
  `remote-injected-<session_id>` is the pattern to reuse: id accepted only as
  `[A-Za-z0-9_-]`, state in the same dir, SessionStart removes and prunes.
- Best effort: the cli **listener** does resolve Claude's session id for a pane
  (`remote-agents.ts` `resolveSessionId` → `detectClaudeSessionIdByPid`, which
  walks the pid tree and falls back to an mtime guess), but it can miss. The
  marker stays directory-keyed anyway: the text hash already disambiguates it,
  and a best-effort id is a poor thing to make the match depend on. Codex, Gemini and Pi
  hooks go through cli `remote-hook` / `gate.ts`; whether their inputs carry a
  stable session id is unchecked, so they need the project-key fallback.
- mcp-server writes `remote-active` after an answered `hwip_ask`. Without those
  two variables it falls back to the newest transcript (wrong with siblings) and
  then to a random `sess_…` — a key written from either would not match the one
  the hooks read, and `config.sessionId` does not record which source it came
  from. A provenance field has to be added, and a session key written only when
  the id is known to be Claude's.
- Claude Code older than session ids in hook input: no `session_id` → project
  key, i.e. today's behavior.

### Options

**A. Leave as is.** Keep the accepted limit, add `/hwip-mode` output that says
the state is shared with other sessions in the directory. No code. Interference
1 stays; it needs two sessions in one directory with one phone-driven.

**B. Everything per session.** Key all files by session id (project key as the
fallback). Fixes all three interferences; breaks "mute this project" across
restarts and resumes, and needs a per-session cleanup (there is no SessionEnd
hook; TTL pruning like P18). cli `gate.ts`, mcp-server and plugin all change
together.

**C. Split by kind (recommended at the time; not chosen — see Status).** Preferences stay per project. Runtime
`remote-active` becomes per session: `remote-active-<hash>-<session_id>`.
Read order: the session's file, then — only when no session id is available —
the project file. `/hwip-mode` stays project-scoped and says so; a later
`--session` flag can add a session-scoped override without moving the default.
Fixes interference 1, the harmful one, and leaves 2 as the documented
project-scope behavior.

### Recommendation and migration path (C)

The constraint is about exit, not about who ships first. Today three writers
touch the project file (plugin hooks, mcp-server after an answered `hwip_ask`,
cli). A reader that looks only at a session file would miss an exit an old
writer performed on the project file — a Done-like answer through an old
mcp-server would stop ending REMOTE, and answered asks would stop refreshing
its TTL. So:

1. **Writers write both keys.** Plugin hooks, mcp-server and the cli write
   `remote-active-<hash>-<sid>` and keep the project file; clear removes both.
   Every old reader still sees the project file, so nothing changes for it.
   mcp-server first needs the provenance field above.
2. **Readers switch, with the project file still required.** A session is in
   REMOTE when the project file is live **and** (its session file is live, or it
   has no session id). Old writers' exits remove the project file and still end
   REMOTE; B's terminal prompt now removes only B's session file, so A keeps
   its REMOTE. Plugin and cli readers change in the same release train, with
   parity vectors for the new read order.
3. **Later, drop the project file for Claude Code** once all three have shipped
   and the session file alone decides.

Reuse P18's id check (`[A-Za-z0-9_-]`) and SessionStart prune. Tests for step 2:
two session ids in one directory, A in REMOTE, B types at the terminal → A
stays; no session id → old behavior; project file removed by an old writer →
REMOTE ends.

### Decisions needed (user) — answered: 4 → A (leave as is until two sessions per directory are seen in use); 1–3 deferred with it

1. Are mute, dial, approve and auto **project** preferences (keep, option C) or
   **session** preferences (option B)?
2. Accept option C for REMOTE — per session, project-key fallback when the
   session id is missing?
3. Is a `--session` flag for `/hwip-mode` wanted now, later, or never?
4. Is the transition (dual-write, then drop) acceptable across three repos, or
   is "leave as is" (A) enough until two sessions per directory is seen in use?

Unverified here: whether `session_id` survives `claude --resume`; whether Codex,
Gemini and Pi hook inputs carry a session id.

## Related
- ADR-0001 (Push Signal): the marker precedent and the "plugin-only vs coupled
  release" trade-off this ADR consciously takes the other side of.
- CORE_RULES.md Rule 9 (sticky REMOTE), Rule 12 (mute); `hooks/gate.sh`
  (`hwip_state_present`); cli `gate.ts` (cksum parity, state dir).
- cli `listener.ts` `tryInject` / `readPaneInfo` — the write site.
