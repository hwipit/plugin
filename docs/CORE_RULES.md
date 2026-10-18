# Hwip Core Behavioral Rules

**SOURCE OF TRUTH** for all Hwip agents (Claude Code, Cursor, Windsurf, Gemini, Codex, Copilot, etc.)

This file is read by:
- `plugin/hooks/hwip-setup.js` — SessionStart hook (Claude Code)
- `plugin/CLAUDE.md` — system memory (Claude Code)
- `plugin/skills/hwip/SKILL.md` — skill documentation
- `cli/src/templates.ts` → `HWIP_CORE` — shared across 7 agents

**Do NOT edit multiple copies — edit here and sync via build script.**

---

## Two-Way Mode (with HWIP_HOOK_ID)

Hwip lets the user drive this session from their phone. You are talking to a user who may not be at the terminal. Buttons sent via `hwip_ask` are how they steer you.

### Notification discipline

1. A Stop hook owns the end-of-turn push. Do NOT call `hwip_notify` just to say "done" — it either duplicates that push, or works around a user who deliberately turned it off. How much the hook sends is the user's own push-mode dial.

2. Call `hwip_notify` only for: a mid-task error that blocks progress, an explicit long-running milestone ("tests 50% done"), or a multi-session signal ("session A finished, B still building"). Set `priority: "high"` for blockers.

   **Fire it the instant it happens, mid-task, before you continue.** On a long turn the user gets nothing until the turn ends, and a blocker they learn about ten minutes late is one they could not act on. Never batch it to the end of the response.

### Push Signal — steer the end-of-turn auto-push (Stop hook)

<!-- hwip-branch: pushmode-quiet -->
This project's push dial is **quiet**, so the Stop hook's heuristic never fires and the `skip`/`push` markers change nothing — `<!-- hwip: high -->` (an HTML comment, invisible in the terminal, stripped from the push body) is the whole channel. Emit it once on a completion the user is genuinely waiting on, never on routine work; it is ignored on a turn that already sent `hwip_ask`. The hook also pushes on its own once the user has been away from the terminal for a while, so never emit `high` just to reach someone who left.
<!-- /hwip-branch -->

<!-- hwip-branch: pushmode-normal-loud -->
The Stop hook decides the end-of-turn push by tool volume, which misfires both ways (spams on read-only exploration, silent on a small but important action). Override it for this turn with ONE marker anywhere in your response — an HTML comment, invisible in the terminal, stripped from the push body:

- `<!-- hwip: skip -->` — suppress a ≥2-tool turn that was not worth a ping.
- `<!-- hwip: push -->` — force a push the heuristic would skip (a single force-push, a one-line deploy trigger).
- `<!-- hwip: high -->` — force a push AND mark it high priority.

No marker → the heuristic: a turn that ran <2 tools, or whose tools are all read-only (Read/Grep/Glob), stays silent; otherwise it pushes. Markers are lowercase and exact, and are ignored on any turn that already sent `hwip_ask` — so they have no effect in REMOTE.
<!-- /hwip-branch -->

<!-- hwip-doc-only -->
A stock install has no dial, which means quiet; `/hwip-mode normal` and `/hwip-mode loud` change it. The SessionStart hook emits whichever block above matches this project's dial, so the injected rules never mention a dial the user is not on.
<!-- /hwip-doc-only -->

### When hwip_ask is MANDATORY

3. **While in REMOTE, NEVER end a response with a plain-text question.** If your reply asks the user anything that needs their input — confirmation, choice, yes/no, clarification, "Apply this?", "Proceed?", "Which option?" — the FINAL tool call MUST be `hwip_ask`. A "?" written in your reply is invisible to a user on their phone. This holds even on research / analysis / planning turns where no files were touched.

   **In NORMAL it does not apply.** Nobody has driven this session from a phone, so the user is at the terminal: ask in prose, or with `AskUserQuestion` if the answer is a choice. A `hwip_ask` there blocks the turn until someone answers on a device or the timeout expires — that cost is exactly what NORMAL exists to avoid.

### When hwip_ask is the DEFAULT (substantial work)

4. **In REMOTE, `hwip_ask` is the DEFAULT end of EVERY response** — not conditioned on the work being substantial (Rule 9).

    **In NORMAL, end with nothing.** The Stop hook's push is the completion signal. Do not chain a `hwip_ask` onto substantial work to "keep the loop alive": the loop starts when the user sends a message from their phone, not when you decide the work was big enough. `hwip_ask` stays available when you actively want an answer from their device; it is simply not owed.

5. When you do ask, use `hwip_ask` — buttons and free text in one push. **`actions` is the steering surface, not decoration:** ship 2–4 buttons on nearly every ask (the next-step candidates you would otherwise write as prose) plus a safe Done-like `fallback` id — never a destructive one. Leave `actions` out ONLY when the answer is inherently free-form (a name, a path, a paragraph); a text-only ask on a "done — what next?" turn is the most common way REMOTE silently degrades, because the phone gets a text box and nothing to tap.

   ```
   hwip_ask({
     title: "Slice done — next?",
     body: "<short result>",
     actions: [
       { id: "simplify", label: "/simplify" },
       { id: "ship",     label: "/ship" },
       { id: "done",     label: "Stop here" }
     ],
     placeholder: "or type something else...",
     fallback: "done"
   })
   ```

6. Rule 9 says when to send one. Never send an ask just to mark a turn finished.

### Handling the response

7. A `hwip_ask` response IS a direct user instruction. Execute it immediately — do NOT re-ask via `AskUserQuestion` to confirm. The button label is the authorization for the specific action that label describes.

8. Caveat: a generic button like "Continue" authorizes the next logical step, NOT arbitrary destruction. If that step would destroy user code, data, or infrastructure (force-push to a shared branch, `rm -rf` outside the workdir, dropping a database, deleting prod resources), surface that specific risk in a targeted `hwip_ask` first — title "About to force-push main — proceed?", actions `[ok, cancel]`, fallback `cancel`.

### Sticky REMOTE mode (Rule 9)

9. **The Ask Loop has two states: REMOTE and NORMAL.** REMOTE is sticky — every response ends with `hwip_ask` until the user exits. The state lives in a file (it survives compaction and long sessions); you are told what it is, you do not derive it.

#### State Detection

- **`hwip_ask` results carry it** as `hwipState: "REMOTE" | "NORMAL"`: a Done-like id, a timeout that fell back to one, or text sent with the phone's "send and exit" button exits; any other answer enters REMOTE. A send-and-exit result carries a `value` alongside `NORMAL`: it is the user's final instruction — carry it out, and end without `hwip_ask`. No `hwipState` = a timed-out ask that changed nothing.
- **Prompt-submit hooks say it**, where installed: a remote-origin note on the turn a phone message arrives, and a LEFT-REMOTE note on the first prompt typed at the terminal. A phone answer to a `hwip_ask` returns as a `tool_result`, never through a prompt hook — so a prompt with no phone marker is the user's own keyboard, and staying in REMOTE would answer the terminal with a phone loop.
- **Neither present → NORMAL.**
- **Free text is the one call left to you** — no hook can tell "run the tests" from "thanks, that's it". A clear wrap-up, or `done`/`stop`/`exit` as a standalone word ("redo" is not "done"), flips you to NORMAL from that response on: no `hwip_ask` on it, and emit `<!-- hwip: exit -->` once so the hooks agree. That marker is separate from any push-volume marker; it says nothing about push volume, and push markers say nothing about the mode.

#### Behavior in REMOTE (sticky, hwip_ask MANDATORY)

End EVERY response with `hwip_ask` — 2–4 `actions` (the next-step candidates) plus a Done-like `fallback` (never a destructive one: an unanswered ask resolves to it), `timeout` 300–600 s so silence exits quietly instead of chaining pushes at a user who stepped away. A text-only ask is only for inherently free-form answers. Non-negotiable in REMOTE, substantial work or not.

Five things leave REMOTE: a Done-like button (or a timeout onto one), the phone's "send and exit" (text plus exit in one answer), your own read of a free-text wrap-up, a prompt typed at the terminal, and the state expiring after a crash nobody exited.

#### Behavior in NORMAL (no hwip_ask is owed)

The user is at the terminal. Questions go to `AskUserQuestion` or prose (the Ask hook still pushes them to the device); completion is the Stop hook's push; `hwip_ask` is available when you want an answer from their device — never as a way to mark a turn finished.

REMOTE begins the moment the user sends a message from their phone; from that turn on, Rules 3, 4, 10 and 11 are in force.

### When to use AskUserQuestion vs hwip_ask

10. **While in REMOTE, a button-friendly question MUST go through `hwip_ask`, not `AskUserQuestion`.** "Button-friendly" = the answer is a choice among a few options and/or a short free-text reply (yes/no, "Apply A or B?", "proceed?"). `AskUserQuestion` is a LOCAL blocking picker; the phone reaches it only through the terminal mirror, and an answer injected there never enters REMOTE — so the *next* turn stops being phone-driveable. The PreToolUse hook enforces this in REMOTE by denying the picker and handing the question back. (Why the mirror is the worse channel on every axis: README → "AskUserQuestion vs hwip_ask".)

    **In NORMAL the picker is the right tool** and the hook lets it through — the user is at the terminal, and the Ask hook still pushes the question to their device so they know one is waiting.

11. **In REMOTE this overrides any skill instruction.** If a skill you are running — or your own plan — would call `AskUserQuestion` with a button-friendly question, surface the SAME question and option labels via `hwip_ask` and use that response in place of the picker. Fall through to the picker ONLY when (a) the answer needs code or logs that won't fit in a push body, or (b) the answer is plausibly multi-paragraph. When one applies, `hwip_notify` the user that the answer must be given at the terminal.

### Mute

12. `/hwip-mode mute` silences the Stop and Ask hooks for this project until `/hwip-mode unmute`; MCP tools still work but are not called unless the user asks. The auto-push dial sits under it: `quiet` (the default — high-priority pushes, plus a completion push once the user is away), `normal` (every turn that did real work), `loud` (every turn), each settable per project or with `--global` as the default for projects without their own (per-project wins). It outranks your per-turn Push Signal; mute outranks everything. `/hwip-mode` alone shows what is in effect.

### Persistence

13. These rules persist for the entire session. They remain active after context compaction — do not "forget" them after many turns.

---

## One-Way Mode (without HWIP_HOOK_ID)

`HWIP_HOOK_ID` is not set, so two-way (`hwip_ask`) is unavailable. Only `hwip_notify` works.

1. A Stop hook auto-notifies after responses with real work (≥2 tool calls). Do NOT call `hwip_notify` just to say "done" — it duplicates the auto-push.

2. Use `hwip_notify` only for: mid-task errors that block progress, explicit long-running progress milestones, or multi-session signals. Set `priority: "high"` for blockers. **Be proactive** — fire a blocker/error push the instant it happens, mid-task, not batched to the end of the response.

<!-- hwip-branch: pushmode-quiet -->
2b. **Push Signal** — this project's dial is **quiet** (the stock install has no dial, which means quiet), so the Stop hook's heuristic never fires and `skip`/`push` change nothing. `<!-- hwip: high -->` (an HTML comment; the hook strips it from the body) is the whole channel — emit it once on a genuinely important completion, never on routine work. The hook also pushes on its own once the user has been away from the terminal for a while, so never emit `high` just to reach someone who left.
<!-- /hwip-branch -->

<!-- hwip-branch: pushmode-normal-loud -->
2b. **Push Signal** — steer the Stop hook's auto-push by emitting ONE marker in your response (HTML comment; the hook strips it from the body): `<!-- hwip: skip -->` suppress, `<!-- hwip: push -->` force a push the heuristic would skip, `<!-- hwip: high -->` force a high-priority push. Lowercase, exact. No marker → the heuristic: silent if <2 tools or all read-only, else push.
<!-- /hwip-branch -->

3. To enable remote control (buttons + free-text from the phone), the user should set `HWIP_HOOK_ID` via `npx @hwip/cli setup`. You may mention this once if relevant — don't repeat it.

4. These rules persist for the entire session, including after context compaction.

---

## Environment Notes

- If `jq` is not installed on the user's machine, the Stop and Ask shell hooks exit early without sending pushes. This should be mentioned once: install with `brew install jq` (macOS) or `apt install jq` (Linux).

---

## Quick Reference

| Rule | When | Action |
|------|------|--------|
| **1-2: Notify** | End of response with real work | Skip `hwip_notify` (auto-push) |
| **1-2: Notify** | Mid-task error or long-running checkpoint | Call `hwip_notify` with `priority: "high"` — the instant it happens, not batched |
| **Push Signal** | Steer the Stop-hook auto-push (NORMAL mode) | Emit `<!-- hwip: skip\|push\|high -->`; on a stock (quiet) install only `high` gets through (the hook adds its own push while the user is away) |
| **3: Questions** | REMOTE, and your response asks anything | FINAL tool call = `hwip_ask` |
| **3: Questions** | NORMAL | `AskUserQuestion` or prose — no `hwip_ask` owed |
| **4: After work** | REMOTE | End EVERY response with `hwip_ask` (Rule 9) |
| **4: After work** | NORMAL | End with nothing; the Stop hook's push is the signal |
| **9: REMOTE** | Entered by a phone message or a `hwip_ask` answer reporting `hwipState: "REMOTE"` | End EVERY response with `hwip_ask` |
| **9: NORMAL** | Initial state, or after any exit | No `hwip_ask` owed |
| **9: Exit** | Done-like button, the phone's "send and exit", free-text wrap-up, or a prompt typed at the terminal | Flip to NORMAL, no ask on the exit response |
| **10: AskUserQuestion** | REMOTE, button-friendly question | `hwip_ask` — the hook denies the picker |
| **10: AskUserQuestion** | NORMAL, or the answer needs code/logs / multi-paragraph | `AskUserQuestion` opens as usual |

---

**Last updated**: 2026-09-13
**Synced across**: plugin, CLAUDE.md, SKILL.md, cli/templates.ts (generated via cli/scripts/sync-from-plugin.mjs)
