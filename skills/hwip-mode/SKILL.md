---
name: hwip-mode
description: >
  Show or change Hwip push notifications for this project: quiet (default),
  normal, loud, mute, unmute; --global sets the default dial. `approve on|off`
  turns the phone approval gate for hard-to-undo commands on or off.
argument-hint: "[quiet|normal|loud|mute|unmute] [--global] | approve on|off"
metadata:
  author: hwipit
  relatedSkills:
    - hwip
    - hwip-auto
  triggers:
    - hwip-mode
    - mute hwip
    - unmute hwip
    - hwip status
    - push mode
    - approval gate
    - /hwip-mode
---

Run this, exactly as written — the arguments go on the heredoc's second line,
never onto the command itself, on one line, and only the words `quiet` `normal`
`loud` `mute` `unmute` `--global` `approve` `on` `off`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/hwip-mode.sh" <<'HWIP_MODE_INPUT'
${CLAUDE_PROJECT_DIR}
$ARGUMENTS
HWIP_MODE_INPUT
```

Exit 2 means a bad argument — show the user the usage line it printed. Otherwise
report the status lines in your own words:

- `NOTIFICATIONS: muted` → the Stop and Ask hooks are silent here; `hwip_*` tools
  still work but are not called unless the user asks. Mute beats every dial.
- `PUSH MODE: quiet` → only high-priority pushes (blockers, `high` Push Signal)
  while the user is at the terminal, plus a completion push once they have been
  away (`HWIP_AWAY_SEC`, default 300 s) or whenever this session's tmux pane is
  not on screen. The shipped default.
- `PUSH MODE: normal` → a push on every turn that did real work, silent on
  read-only turns; the Push Signal markers decide the edge cases.
- `PUSH MODE: loud` → every turn pushes, overriding `skip`.
- The parenthesis says where the dial came from: `this project`, `global default`
  (set with `--global`, inherited by projects without their own dial), or the
  built-in default. A project dial always beats the global one.
- `APPROVAL GATE: on|off` → whether hard-to-undo Bash commands (`rm -rf`, force
  push, prod deploy, destructive SQL) wait for approval in this project. At the
  terminal Claude Code's own permission prompt asks; away, in REMOTE, or when
  presence can't be read, the user's phone does. `on, but inactive while muted`
  — a muted project has no one to ask, so nothing is held.
- `SCOPE: …` → the dials, mute, approval gate and auto mode belong to the project directory, not
  the session: a second Claude session in the same directory shares them. Say so when
  the user changes one.
- `AUTO MODE: …` → a `/hwip-auto` session is running with that much budget left.
  `off (an expired … session left its state behind — cleared)` means one crashed.
- `LAST PUSH: …` → the CLI's record of its last failed push (`hwip notify` writes
  it, a good push deletes it). The hooks hide notify's errors, so this line is
  how "quiet, nothing to send" differs from "every push fails". Relay the cause
  and its fix as given (e.g. a rejected key → `hwip login`, no app signed in →
  sign in to the Hwip app on an iPhone or Android phone); `hwip verify` has more.
- `Hwip: <device> changed its encryption key — …` → not a failure: one of the
  user's devices now lists another encryption key than this machine had pinned,
  and the new key is trusted. Shown once, then cleared. Relay it as that — a
  reinstalled app or a new phone explains it; if neither does, `hwip trust` shows
  the fingerprints to compare with the app.

Questions (`hwip_ask`, the AskUserQuestion mirror) push under every dial except mute.

The context a sealed question carries (the session's masked git diff and last
terminal lines) is not a dial here. If the user asks to stop
sending it, point them to `hwip ask-context off` (this project) or
`hwip ask-context off --global` (every project); `hwip ask-context` shows which applies.

If the output ends with a `=== Hwip rules — replace the Hwip rules from session start ===`
block, the state changed and the rules the SessionStart hook gave this session are
stale: follow that block instead for the rest of the session, including after
compaction. `Session rules unchanged` means the change did not touch them (e.g.
normal ↔ loud); keep the ones you have. `approve` never changes the rules. A `could not refresh` line means the change still applies but the
rules did not update — tell the user a new session picks them up.
