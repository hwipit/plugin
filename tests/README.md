# Plugin tests

Fixture-based tests for the bash hooks under `hooks/`. No external test
framework — plain bash with a small assert helper. The hook itself
requires `jq` and `python3`; the tests inherit the same requirements.

## Running

```bash
# Run every suite
bash tests/run-all.sh

# Or one suite at a time
bash tests/test-hwip-stop.sh
bash tests/test-hwip-ask.sh
bash tests/test-hwip-remote.sh
```

Exits 0 when all tests pass, non-zero otherwise. CI runs `run-all.sh` on
every PR via `.github/workflows/test.yml`, on Ubuntu and on macOS — the macOS
job pins `bash` to the system 3.2 and runs with the BSD tools users have.

## What's covered

The tests target scenarios that broke in the 0.5.0–0.5.3 hotfix cycle —
each one would have failed before the corresponding fix landed:

| Test | Catches |
|------|---------|
| `string-content turn detection` | The 0.5.8 fix — current Claude Code logs typed user messages with `.message.content` as a string. The 0.5.1 crash guard turned strings into `[]`, so `is_real_user` stopped detecting real turns and `since_last_user` silently scoped every check to the whole transcript. |
| `legacy array-form user message` | `is_real_user` still matches the older array-of-blocks user-message shape (the `or` branch). |
| `off-by-one — turn-2 push must not leak turn-1 text` | The 0.5.8 fix — with turn detection broken, a Stop hook that fired before the final text flushed produced a push carrying the *previous* turn's answer. |
| `subagent transcript silenced` | The 0.5.2 hotfix — Claude Code fires the Stop hook for sub-agent terminations too. |
| `observer transcript silenced` | The 0.5.2 hotfix — claude-mem spins up Claude sessions (`*-claude-mem-observer-sessions/`) whose Stop event also fires our hook. |
| `a user project with 'observer' in its path still pushes` | The old `*observer*` glob silenced every such project for good. |
| `late flush — final text with a high marker lands late` | The text wait keyed on *empty* text, so a turn with a mid-turn text line read that line, missed the final marker and pushed the wrong body. A background writer appends the final text 0.3 s in. |
| `no CLAUDE_PROJECT_DIR — title falls back to the working directory` | The title used to go out as a bare "Claude: ". |
| `python3 that fails to run — body keeps the summary` | macOS's `/usr/bin/python3` stub exits non-zero without the developer tools; the trim returned nothing and the summary was lost. |
| `multi-turn scoping respects the LAST real user turn` | Per-turn `TOOL_COUNT` must not leak across turns — regresses if string-content turn detection breaks. |
| `long Korean summary >512B triggers CLI file-upload path` | The 0.5.3 hotfix — earlier 280-char trim collapsed summaries below the CLI's 512-byte threshold, suppressing file attachment. |
| `empty SUMMARY falls back to default body` | Safety-net that 0.5.3 amend re-added. |
| `body stays under 15000-byte safety cap` | The 5000-codepoint upper bound, matching 0.4.0 behavior. |
| `1-tool turn stays silent` | The basic `TOOL_COUNT < 2` gate. |
| `turn with hwip_ask silenced` | The basic dedup that lets `hwip_ask` replace the Stop push. |
| `muted project skips push` | The `<stateDir>/muted-<hash>` opt-out (plus the user-owned legacy `/tmp` fallback). |
| `read-only floor stays silent` | The B1 floor — a turn whose tools are all Read/Grep/Glob is exploration noise and is suppressed. |
| `marker skip / push / high` | The Push Signal — `<!-- hwip: skip\|push\|high -->` overrides the heuristic (suppress / force / force+`--priority high`); the marker is stripped from the body. |
| `no-space + newline-split marker leak guard` | Detect and strip share one `[[:blank:]]`-based pattern, so a malformed marker can't be detected-but-not-stripped (no leak) and a newline-split marker is honoured by neither. |
| `push mode quiet / loud` | The `pushmode-<hash>` dial — quiet keeps only high pushes while the user is present, loud pushes every turn (still respecting dedup), cleared restores the default. |
| `away: …` | `hwip_is_away` with stubbed `tmux`/`ioreg` on PATH — quiet pushes once the user is away (HID idle, no tmux client, stale `client_activity` over SSH), a readable HID outranks tmux, failed probes and a broken `HWIP_AWAY_SEC` read as present/default, and normal/loud/high turns never probe. A session whose tmux pane is hidden (no client, another window, another pane zoomed) counts as away even while the user types elsewhere; no `TMUX_PANE`, a silent tmux, odd output, an iTerm2 `-CC` client and `HWIP_AWAY_SEC=0` narrow nothing. |

### Hook time budget (`test-hwip-stop-deadline.sh`)

Wall-clock cases, so the suite sleeps for real (~25 s): a stub `tmux` that answers each call after a set delay, a stub `hwip` that can hang.

| Test | Catches |
|------|---------|
| `a tmux that answers instantly` | The deadline changes no verdict for a healthy tmux: hidden pane → push, visible pane → silent, no client attached → push. |
| `a tmux that answers each call just inside its 2 s bound` | P30-Stop — each probe had its own 2 s bound, so 4 slow calls × 2 hook calls took 14.8 s, past `plugin.json`'s 10 s. Now the hook ends inside 9.5 s and the cut probes read as present (no push); the probes run once per hook run. |
| `its first answer settles it` / `a hung push CLI after that` | An answer that came in time still pushes, and the CLI is bounded by what is left of the hook budget (8.1 s, was 11.9 s), not a fresh 8 s. |
| `only the control-mode probe hangs` | A control-mode probe that is skipped or times out under the Stop hook is unknown, not hidden — `hidden` would add a push on no evidence. |
| `a tmux that never answers` | Still present, no push, inside the cap. |

### hwip-herdr.sh (`test-hwip-herdr.sh`)

`tmux` and `herdr` are stubs (tmux answers the session's herdr options, herdr logs its argv). The no-op rows matter most — the hook runs on every tool call of every session.

| Test | Catches |
|------|---------|
| `no-ops` | Outside tmux, in a tmux session with no herdr options (including a CLI that does not write them yet), on a tool call that changes nothing, and in a headless `claude -p` (`CLAUDE_CODE_ENTRYPOINT=sdk-cli`, whose SessionEnd would release the pane's real agent): nothing is sent. |
| `lifecycle` | start → `idle`, prompt → `working`, permission prompt → `blocked`, tool after it → `working`, Stop → `idle`, SessionEnd → release; a state equal to the last is not resent. |
| `seq` / `reattach` | `--seq` only grows (herdr drops a report whose seq is not above the last); a new herdr pane gets the state even when it did not change. |
| `bounds` | A `herdr` path with a space still runs; a tmux that never answers is cut inside the 5 s hook cap — with `timeout` on PATH, and with only perl (stock macOS). |
| `options` | An empty or non-executable bin option falls back to `herdr` on PATH; `start` re-claims the pane even when the state is unchanged. |
| `session start` | SessionStart fired by a compaction (often mid-turn) reports nothing — `idle` there would stick until the next prompt; a fresh session claims the pane. |
| `empty fields` | An empty pane option next to a socket is not read as `pane=socket` (the options are split on a unit separator, not a tab). |

### hwip-ask.sh

| Test | Catches |
|------|---------|
| `single .tool_input.question` | The standard Claude Code AskUserQuestion shape. |
| `multi-question .tool_input.questions[0].question` | The newer AskUserQuestion format with parallel questions. |
| `no question field → 'Question pending' fallback` | Defends against schema changes. |
| `Korean ≤ 200 codepoints (UTF-8 safe)` | The python3 trim; old `head -c 200` cut mid-byte and produced mojibake. |
| `muted project skips push` | Same `<stateDir>/muted-<hash>` opt-out. |
| `title carries project basename` | Verifies CLAUDE_PROJECT_DIR plumbing. |
| `invalid JSON input doesn't crash` | `jq` errors are absorbed; fallback text still fires. |
| `no CLAUDE_PROJECT_DIR — title falls back to the working directory` | Same fallback as the Stop hook. |
| `python3 that fails to run — body still carries the question, capped` | The trim fell through to nothing and the push body went out blank; it now falls back to a bash substring. |

### hwip-setup.js (`systemMessage`)

| Test | Catches |
|------|---------|
| `unconfigured / muted / no jq → user-visible message` | These states silence the plugin; the note used to reach only the model, never the user's screen. |
| `configured with jq → no message` | A working install shows nothing extra. |

### Last push failure (`test-hwip-mode.sh`, `test-hwip-setup.sh`)

| Test | Catches |
|------|---------|
| `last push failure — the CLI's record, read only` | `/hwip-mode` prints `LAST PUSH:` from `fixtures/last-notify-failure.json` — the exact line cli `src/notify-failure.test.ts` pins as what `hwip notify` writes. `no-app` and `unsealed` (refusals before anything was sent) name the fact with no HTTP status. The retired key-change and `plaintext` kinds, an unknown version, a non-ISO timestamp or a prototype key as `kind` read as no failure, and file text never runs. |
| `last push failure — shown to the user in every configured state` | SessionStart's `systemMessage` carries the failure next to the mute or jq note, and nothing once the record is gone. |
| `key changes — kept by whoever replaced a pin, shown once` / `key changes — shown once at session start, then gone` | `/hwip-mode` and SessionStart print one `Hwip: <device> changed its encryption key …` line per entry of `~/.hwip/key-changes.json` (`fixtures/key-changes.json` = the line cli `src/key-changes.test.ts` pins) and delete the record, so a second run says nothing. A name loses its control characters; an entry whose id or time is not one is dropped; a broken record or another version shows nothing and is cleared; file text never runs. While a writer holds `~/.hwip/trusted-devices.lock` nothing is taken and the record stays; a lock older than 10 s is broken; with no record no `~/.hwip` is made. |

### Approval gate (`test-hwip-approve.sh`, `test-hwip-mode.sh`)

| Test | Catches |
|------|---------|
| `at the terminal — Claude Code's own prompt` | With a stubbed `ioreg` reading 10 s idle and `permission_mode` default / acceptEdits / plan, the hook answers `ask` and never pings the phone — it used to make a present user wait 75 s for a phone answer. |
| `presence never turns the gate into an allow` | bypass-style modes, no mode, away, unreadable presence and REMOTE all keep the phone; none of them can produce `allow` without an Approve. |
| `the phone says why there was no answer` | `hwip ask`'s `reason` — a cancel says "do not retry", a timeout and an error say what they are. |
| `a NUL in the command shows up in the body instead of vanishing` | `$(jq …)` dropped the NUL, so the approval window showed `ab` for a command that was `a\0b`. The body now carries U+2400 where the byte was. |
| `approval gate — /hwip-mode approve on\|off` | The switch writes and removes `approve-<hash>`, status shows it (and that mute makes it inactive), and it never reprints the session rules. |
| `a change that leaves the rules as they were` / `auto mode — an expired deadline` | normal → loud prints one line instead of the rules block; a crashed `/hwip-auto` session's file is cleared instead of showing negative minutes. |
| `no CLAUDE_PROJECT_DIR — hashes what the shell hooks hash` (`test-hwip-setup.sh`) | SessionStart keyed state on `process.cwd()` (physical path) while the shell hooks used `$PWD`, so a symlinked cwd split mute / dial / REMOTE. |

### CLI start and state-file times (`test-hook-cli-and-state.sh`)

| Test | Catches |
|------|---------|
| `a hwip whose path holds a space` | The hooks kept the CLI as one string and split it again, so `/Users/Jane Doe/…/hwip` started `/Users/Jane`: no push ever left, and every approval was denied. Now an array (`hwip_cli_command`), checked for the approval, stop and ask hooks. |
| `no hwip, so npx -y @hwip/cli` | The fallback stays three words (`-y`, `@hwip/cli`) after the change to an array. |
| `the CLI cannot be started` | The approval hook's deny reason follows what the shell saw: exit 126/127 "Could not start the hwip CLI", 124 "did not finish", another code names it; only a CLI that ran and said nothing gets the 75 s message. |
| `hwip_remote_active reads a time that bash would take for octal` | A leading 0, 13+ digits and a future time. The first used to stop the shell with "value too great for base"; the last kept REMOTE live until the clock caught up. |
| `the denied-question stamp and the phone-origin marker` / `the idle time ioreg reports` | The other places that subtract a number a file or a probe gave them go through `hwip_age_sec` too. |

### Shared test state (`test-no-shared-test-state.sh`)

| Test | Catches |
|------|---------|
| `no project directory at a fixed path` / `no state dir named by $RANDOM` | The hooks key legacy files on a hash of the project directory, so a project at a fixed path (`/tmp`, `/tmp/test-project`) is the same project for every run: two runs of `test-hwip-stop.sh` set each other's push mode (12 of 12 parallel runs failed), and a `/tmp/hwip-muted-<hash>` left for it silenced 35 cases of `test-hwip-ask.sh`. bash 3.2 returns the same `$RANDOM` in every `$(...)`, so a state dir "unique" by it was one dir for the whole run. Projects now live under each run's `$WORK`. |

### stdin drain (`test-stdin-drain.sh`)

| Test | Catches |
|------|---------|
| `<hook> drains stdin before exiting` | Each shell hook exited on the jq check (and on mute / not-enabled) before reading its input, leaving Claude Code's writer to take a SIGPIPE. Runs every hook on a PATH without jq against 1 MiB of input. |

### hwip-remote.sh (ADR-0002)

| Test | Catches |
|------|---------|
| `fresh marker + matching prompt → REMOTE context` | The happy path: additionalContext emitted, marker consumed one-shot. |
| `HWIP_HOOK_ID unset → one-way conversion CTA` | The funnel branch — no two-way claim, `cli setup` mentioned. |
| `text mismatch → silent, marker kept` | The exact-hash guarantee: a terminal keystroke racing a phone message can't false-flag REMOTE. |
| `stale marker (>15 min) → silent, marker deleted` | The freshness window survives long mid-turn queueing; dead markers are cleaned up on sight. |
| `muted project → marker left unconsumed` | Mute outranks detection (Rule 12). |
| `whitespace-padded / multi-line / NBSP prompts` | Both sides trim the same explicit ASCII whitespace set (Unicode spaces like U+00A0 stay in the digest); multi-line bodies match byte-for-byte. |
| `malformed marker → silent, exit 0` | The hook must never block a prompt. |
| `legacy /tmp marker honored` | Same `hwip_state_present` resolution (user-owned legacy fallback) as every other state file. |

### .mcp.json launch (`test-mcp-launch.sh`)

| Test | Catches |
|------|---------|
| `hwip on PATH → hwip mcp` | A global install keeps the in-process `hwip mcp` server. |
| `no hwip on PATH → npx -y @hwip/cli mcp` | An `npx @hwip/cli install` user has no `hwip` binary; a bare `"command": "hwip"` never started the MCP server. Stubbed `hwip`/`npx` on a private PATH. |

## Fixtures

JSONL transcripts in `fixtures/` match the shape Claude Code writes —
one event per line. `.message.content` is a **string** for typed user
messages and system prompts, and an **array of content blocks** for
assistant turns and tool results. (`main-array-user-2-tools.jsonl`
keeps the legacy array-wrapped user-message shape covered.) The
`gen-long-summary.sh` script regenerates the >512-byte Korean fixture
deterministically; the long fixture is also checked in so CI doesn't
need python3 at fixture-generation time (only at test-run time, which it
already needs for the trim helper).

## Adding tests

1. Write or generate a `.jsonl` fixture under `fixtures/`.
2. In `test-hwip-stop.sh` add a `run_hook` + `assert` / `assert_not`
   block describing the expected behaviour.
3. Run the suite locally before pushing.

Keep one fixture per scenario rather than reusing — readability beats
DRY for transcripts, since the failure mode is usually "this exact
shape of input".
