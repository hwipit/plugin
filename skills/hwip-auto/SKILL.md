---
name: hwip-auto
description: >
  Time-boxed autonomous work session — explore → plan → implement → verify →
  commit in a loop until the time budget runs out. Every decision goes through
  hwip_ask with a timeout fallback, so work never stalls on an absent user.
  Start ONLY on explicit user request (e.g. /hwip-auto 2h). Requires a hook id.
disable-model-invocation: true
metadata:
  author: hwipit
  relatedSkills:
    - hwip
    - hwip-mode
    - hwip-config
  triggers:
    - hwip-auto
    - autonomous mode
    - autonomous work
    - unattended session
    - time-boxed session
    - /hwip-auto
---

# Hwip Auto — Time-Boxed Autonomous Work Mode

Work autonomously for a fixed time budget: explore → plan → implement → verify →
commit, one unit at a time. The user steers from their phone via `hwip_ask`
buttons; when they don't answer, you proceed on a stated safe default instead of
stalling. The whole run happens in a single response — ending your turn ends the
mode.

## Preconditions — refuse to start if not met

- **A hook id is configured** — `hookId` in `~/.hwip/config.json` (what
  `hwip install` writes), or the `HWIP_HOOK_ID` override. The SessionStart
  context ends with `Mode: two-way (notify + ask)` when one is; `Mode: one-way`
  means there is no steering channel — refuse and point the user to `/hwip-config`.
- **Not muted.** If `/hwip-mode` reports `NOTIFICATIONS: muted`, refuse: autonomous mode
  without notifications is unattended work with no steering. Suggest `/hwip-mode unmute`.
- **Explicit user invocation.** Never self-trigger this mode because a task
  "looks long". The user opts in with `/hwip-auto ...`.

## Arguments

`/hwip-auto [duration] [task description...]`

- **duration** — `2h`, `90m`, `1h30m`, or a bare number meaning minutes.
  Default: `1h`. Clamp to 10m–8h.
- **task** — everything after the duration. If omitted, derive it from the
  conversation so far; if there is none, propose 2–3 candidate tasks in the
  kickoff ask (e.g. fix failing tests, clear lint warnings, a TODO sweep).

## Setup

1. **Record the deadline** (a state file survives context compaction — re-read
   it whenever you are unsure how much time is left):

   ```bash
   HASH=$(printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
   STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hwip"
   mkdir -p "$STATE_DIR"
   MINUTES=120   # parsed from the duration argument
   DEADLINE=$(( $(date +%s) + MINUTES * 60 ))
   printf '%s %s\n' "$DEADLINE" "$MINUTES" > "$STATE_DIR/auto-$HASH"
   date -r "$DEADLINE" 2>/dev/null || date -d "@$DEADLINE"   # macOS | Linux
   ```

2. **Protected-branch guard** — never work directly on `main`/`master`/`develop`:

   ```bash
   BRANCH=$(git branch --show-current 2>/dev/null)
   case "$BRANCH" in
     main|master|develop) git checkout -b "auto/$(date +%Y%m%d)-<task-slug>" ;;
   esac
   ```

3. **Discover the verifier** before writing any code: the project's deterministic
   checks (test / lint / typecheck / build commands from package.json, Makefile,
   CI config). These gate every commit. If the project has none, say so in the
   kickoff ask and treat "code compiles/runs" as the minimum gate.

4. **Kickoff ask** — one `hwip_ask` before touching anything:
   - `title`: "Auto mode: <task> (<budget>)"
   - `body`: 2–3 line plan + which verifier gates commits + the branch name
   - `actions`: `[{id:"start", label:"Start", style:"primary"}, {id:"stop", label:"Cancel"}]`
     (if the task was ambiguous, replace "Start" with 2–3 candidate-task buttons)
   - `placeholder`: "adjust the plan or scope..."
   - `timeout`: 180, `fallback`: `"start"` (or the recommended candidate)

   Free-text replies amend the plan; `stop` cancels the mode (remove the state file).

## The Loop

Split the task into **units**: the smallest independently verifiable, committable
chunks (~15–45 min each). Then for each unit:

1. **Time check** (before starting every unit):

   ```bash
   HASH=$(printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}" | cksum | cut -d' ' -f1)
   read -r DEADLINE MINUTES < "${XDG_STATE_HOME:-$HOME/.local/state}/hwip/auto-$HASH"
   echo "remaining: $(( (DEADLINE - $(date +%s)) / 60 ))m of ${MINUTES}m"
   ```

   If remaining time is under the wrap-up threshold — **10% of the budget, at
   least 5 minutes** — do not start a new unit; go to Wrap-Up.

2. **Explore → plan** the unit (read the relevant code first; no blind edits).
3. **Implement** the unit.
4. **Verify** with the deterministic checks. Green is the only pass signal —
   "looks correct" is not a verifier, and never weaken or delete a failing test
   to get to green. On failure, fix and re-verify, **at most 3 attempts**; if
   still red, revert the unit's changes (`git checkout -- <files>` / `git stash`)
   so the tree stays clean, record it as skipped, and move on.
5. **Commit** the green unit with a clear conventional message. Do NOT push.
6. **Heartbeat** — after a commit, a short `hwip_notify` ("✅ <unit> — <n>m
   left"), but at most one per ~15 minutes; batch small units. Blockers are the
   exception: push a `priority: "high"` notify the instant one appears.

Repeat until the units are done or the wrap-up threshold hits.

## Question Protocol — never stall, never destroy

Questions mid-run go through `hwip_ask` (never `AskUserQuestion`, never plain
text — CORE_RULES rules 3/10 apply):

- Put the **recommended default first**, note in the body that it auto-proceeds
  on timeout, set `timeout: 180` (up to 600 for genuinely large decisions) and
  `fallback` to that default's id.
- **Log every decision that resolved by fallback** — the final report lists them
  so the user can audit what was decided without them.
- Any reply is a direct instruction: apply it immediately. A `stop` reply (or
  free-text session-ender) means wrap up now.
- **Irreversible or outward-facing actions are never fallback-eligible**: push,
  PR/publish, deploy, data deletion, schema drops, force ops, anything outside
  the working tree. For these the fallback MUST be `skip` — on timeout you skip
  the action and note it, you do not do it. Only an explicit button tap
  authorizes it.

## Wrap-Up

1. Finish or revert the in-flight unit (same 3-attempt rule — never leave the
   tree red or dirty).
2. Remove the state file: `rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/hwip/auto-$HASH"`.
3. **Final report** in your response text: units completed (with commit hashes),
   units skipped and why, every fallback-resolved decision, and what's left.
4. **Final ask**:
   - `actions`: `[{id:"extend", label:"+30m"}, {id:"review", label:"Review"}, {id:"done", label:"Done", style:"primary"}]`
   - `timeout`: 300, `fallback`: `"done"`
   - `extend` → write a new deadline (+30m) to the state file and re-enter the
     loop; `review` → walk through the diff; `done` → end.

## If Things Go Wrong

- **No hook id** (`Mode: one-way`) — two-way tools are unavailable; auto mode cannot run.
  Run `/hwip-config` to set it up.
- **State file missing mid-run** (e.g. state dir cleared): treat the deadline as
  now — wrap up rather than guess how much budget is left.
- **User types in the terminal mid-run**: that message is steering input, same
  as a `hwip_ask` reply. Apply it and continue the loop.
- **Verifier is flaky** (same command alternates green/red with no change):
  don't burn attempts on reruns — report it as a blocker via `hwip_notify`
  (`priority: "high"`) and move to the next unit.
