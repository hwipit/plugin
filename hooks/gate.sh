# Shared hook library — sourced by every shell hook (stop, ask, approve,
# remote) and scripts/hwip-mode.sh; no shebang, no exit. Two halves,
# mirroring cli/src/gate.ts:
#   1. hwip_gate_decide — the pure decision function (vector-locked, below)
#   2. state-file resolution + CLI bounding helpers (mirrored by convention)
#
# This is the PORTABLE half of the Stop hook: a pure function from turn facts
# to a push verdict. Its semantics are locked to cli/src/gate.ts (@hwip/cli)
# by the shared vector file tests/fixtures/gate-vectors.json — both this bash
# implementation and the TS twin run the exact same cases in CI, so a change
# to one that isn't mirrored in the other fails a build. Edit semantics ONLY
# together with the vectors.
#
# hwip_gate_decide <tool_count> <nonreadonly_count> <already_asked> <marker> <pushmode> [away]
#   tool_count        — total tool_use blocks this turn
#   nonreadonly_count — tools that are NOT read-only (Read/Grep/Glob)
#   already_asked     — count of hwip_ask this turn (>0 = notified)
#   marker            — skip | push | high | anything else = none
#   pushmode          — quiet | loud | anything else (incl. missing) = normal
#   away              — 1 = the user is away from the terminal (hwip_is_away);
#                       anything else (incl. missing) = present
# Prints exactly one of: "push high" | "push normal" | "silent".
#
# This function decides NOTHING about what an install with no dial gets — that
# is hwip_read_pushmode's job, below. Keeping it out of here is what lets the
# vector file stay a complete contract: every input this function accepts, the
# TS twin's decidePush answers identically, so any case can become a vector.
#
# Ordering is contractual (encoded as named vectors):
#   1. already_asked wins over EVERYTHING — even loud (dedup beats the dial).
#   2. priority is high iff marker=high, decided BEFORE the mode switch, so
#      quiet+high and loud+high both push at high priority.
#   3. quiet → a high marker or an away user pushes; loud → always push; normal → marker
#      overrides the heuristic (skip → silent, push/high → push), no marker →
#      push iff tool_count ≥ 2 AND nonreadonly_count > 0 (B1 read-only floor).
hwip_gate_decide() {
    local tool_count="${1:-0}" nonreadonly_count="${2:-0}" already_asked="${3:-0}"
    local marker="${4:-none}" pushmode="${5:-normal}" away="${6:-0}"

    [ "$already_asked" -gt 0 ] 2>/dev/null && { echo "silent"; return 0; }

    local priority="normal"
    [ "$marker" = high ] && priority="high"

    case "$pushmode" in
        quiet)
            [ "$marker" = high ] || [ "$away" = 1 ] || { echo "silent"; return 0; }
            ;;
        loud) : ;;
        *)
            case "$marker" in
                skip) echo "silent"; return 0 ;;
                high|push) : ;;
                *)
                    [ "$tool_count" -lt 2 ] 2>/dev/null && { echo "silent"; return 0; }
                    [ "$nonreadonly_count" -eq 0 ] 2>/dev/null && { echo "silent"; return 0; }
                    ;;
            esac
            ;;
    esac

    echo "push $priority"
}

# ── AskUserQuestion routing (hwip-ask.sh) ────────────────────────────────────
#
# CORE_RULES rules 10/11 say a button-friendly question must go through
# `hwip_ask` rather than the local AskUserQuestion picker, and carve out two
# cases where the picker is still right: the answer needs code or logs that
# won't fit a push body (a), or the answer is plausibly multi-paragraph (b).
# Until now that rule lived only in prose, so breaking it failed silently.
# This function is the machine reading of it: `deny` means the PreToolUse hook
# blocks the picker and hands the model the same question to re-ask through
# `hwip_ask`, `allow` means the picker opens as before.
#
# hwip_ask_decide <hookid_present> <muted> <has_preview> <question_chars> <option_chars> <replay> <remote>
#   hookid_present — 1 when a hook id resolves (hwip_hook_id: env or config.json)
#   muted          — 1 when this project is muted
#   has_preview    — 1 when any option carries a `preview` block
#   question_chars — length of the question stem
#   option_chars   — longest label+description across the options
#   replay         — 1 when this exact question was denied moments ago
#   remote         — 1 while sticky REMOTE is live for this project
# Prints exactly one of: "deny" | "allow".
#
# ALLOW IS THE SAFE DIRECTION and every uncertain input must reach it. A wrong
# `allow` costs the user one trip to the terminal; a wrong `deny` can leave a
# session with no way to ask anything at all. Hence: no hook id → allow (there
# are no two-way tools to route to), muted → allow (routing to `hwip_ask` would
# push around the mute the user set), unparseable numbers → 0 → allow via the
# hookid check.
#
# NOT IN REMOTE → allow, and this is the load-bearing one. A hook id says the
# user *can* drive from their phone, not that they are: a session in NORMAL is
# one nobody has driven remotely, so blocking the picker there takes the local
# picker away from a user sitting at the keyboard and gives them nothing back.
# Rule 10 still says a button-friendly question belongs in `hwip_ask` whenever
# the hook id is set — that rule is for the model to follow. This function only
# decides where the deterministic block is worth its cost, and that is exactly
# where the picker is demonstrably unreachable: REMOTE.
#
# `replay` outranks everything. If the model cannot reach `hwip_ask` — MCP
# server down, tool not exposed — it will retry AskUserQuestion, and a second
# deny would trap the session. The retry gets through instead.
#
# The two limits are the carve-outs made countable. They are deliberately
# generous: the question is whether the text still fits a phone notification,
# not whether it is short.
HWIP_ASK_MAX_QUESTION_CHARS=400
HWIP_ASK_MAX_OPTION_CHARS=240

hwip_ask_decide() {
    local hookid="${1:-0}" muted="${2:-0}" has_preview="${3:-0}"
    local question_chars="${4:-0}" option_chars="${5:-0}" replay="${6:-0}"
    local remote="${7:-0}"

    [ "$replay" = 1 ]      && { echo allow; return 0; }
    [ "$hookid" != 1 ]     && { echo allow; return 0; }
    [ "$muted" = 1 ]       && { echo allow; return 0; }
    [ "$remote" != 1 ]     && { echo allow; return 0; }
    [ "$has_preview" = 1 ] && { echo allow; return 0; }

    # Anything non-numeric means the measurement failed, and a failed
    # measurement must not become a deny: `[ x -gt 400 ]` errors, the `&&`
    # below never fires, and control would fall through to deny — the one
    # direction this function is not allowed to guess in.
    case "$question_chars$option_chars" in
        ''|*[!0-9]*) echo allow; return 0 ;;
    esac

    [ "$question_chars" -gt "$HWIP_ASK_MAX_QUESTION_CHARS" ] && { echo allow; return 0; }
    [ "$option_chars" -gt "$HWIP_ASK_MAX_OPTION_CHARS" ] && { echo allow; return 0; }

    echo deny
}

# hwip_hook_decision <allow|deny|ask> <reason> — emit a PreToolUse decision.
#
# One definition of the envelope. It was written out by hand in three places
# (the ask hook's deny, and both branches of the approval hook), so the field
# names lived in three places too and a fourth field would have had to be added
# to all of them without drifting.
#
# `jq -n --arg` does the escaping: a reason carries a user's question verbatim,
# quotes, newlines and all.
hwip_hook_decision() {
    jq -n --arg decision "$1" --arg reason "$2" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $decision, permissionDecisionReason: $reason}}' \
        2>/dev/null
}

# ── Per-project state + CLI bounding (shared by both hooks) ──────────────────

# Mute/push-mode/auto state lives under a per-user dir. It used to sit at
# predictable names in world-writable /tmp, where any local user could
# pre-create a victim's mute file (sticky /tmp makes it un-deletable by the
# victim). Legacy /tmp files are honored during migration, but only when
# owned by the current user (-O), which neutralizes planted files. The TS
# twin is cli/src/gate.ts findStateFile — keep them behaviorally in sync.
HWIP_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hwip"

# hwip_state_present <kind> <hash> — kind is muted|pushmode|auto|remote. Echoes
# the live state-file path, rc 1 if none. (`remote` is the one-shot phone-origin
# marker the listener writes and hwip-remote.sh consumes — see ADR-0002.)
#
# `pushmode` alone has a machine-wide default (`pushmode-default`, written by
# `/hwip-mode quiet --global`), consulted last so a per-project dial always wins.
# `cksum` emits digits only, so `-default` can never collide with a real hash.
# Mute is deliberately project-only: a global mute file would have no way to be
# lifted for one project (presence, not content, is the signal), and a global
# `quiet` already covers "stop the routine pushes everywhere".
hwip_state_present() {
    if [ -f "$HWIP_STATE_DIR/$1-$2" ]; then
        echo "$HWIP_STATE_DIR/$1-$2"
    elif [ -f "/tmp/hwip-$1-$2" ] && [ -O "/tmp/hwip-$1-$2" ]; then
        echo "/tmp/hwip-$1-$2"
    elif [ "$1" = pushmode ] && [ -f "$HWIP_STATE_DIR/pushmode-default" ]; then
        echo "$HWIP_STATE_DIR/pushmode-default"
    else
        return 1
    fi
}

# Push mode for an install that has never set a dial. The TS twin is
# cli/src/gate.ts PUSHMODE_DEFAULT — the vector file cannot lock this, because
# neither side's pure decision function is where it lives, so both sides pin it
# in their own tests.
HWIP_PUSHMODE_DEFAULT=quiet

# hwip_read_pushmode <hash> — the effective dial for a project. The bash twin of
# cli/src/gate.ts readPushMode; keep them behaviorally in sync.
#
# Three failure shapes, and only one of them gets the quiet default:
#   - no hash (cksum unavailable, so no state file can be keyed) → normal
#   - no dial file anywhere                                      → the default
#   - a dial that is empty, unreadable, or not one of the three
#     recognised words                                           → normal
# The two `normal` rows are the same judgment: a broken setting is not an
# expression of intent, and resolving breakage to silence leaves the user with
# the one symptom they cannot tell apart from working correctly. The TS twin
# reaches the same answers — `if (!hash) return 'normal'` and
# `normalizePushMode`, which maps both '' and garbage to normal.
hwip_read_pushmode() {
    local hash="$1" file mode
    [ -n "$hash" ] || { echo normal; return 0; }
    file=$(hwip_state_present pushmode "$hash") || { echo "$HWIP_PUSHMODE_DEFAULT"; return 0; }
    mode=$(tr -d '[:space:]' < "$file" 2>/dev/null)
    case "$mode" in
        quiet|loud|normal) echo "$mode" ;;
        *)                 echo normal ;;
    esac
}

# ── CORE_RULES.md section extraction ────────────────────────────────────────
#
# hwip_core_section <heading> — print one `###` section of docs/CORE_RULES.md,
# heading included, up to the next heading of the same or a higher level
# (`####` subsections stay in). rc 1 and no output when the file or the heading
# is missing, so a caller can fall back rather than emit an empty rule block.
#
# The JS twin is `section()` in hooks/hwip-setup.js — same slice, same reason:
# both hooks inject a subset of the rules rather than the whole document, and
# neither may keep its own copy of the text that CORE_RULES.md owns. NOT the
# same post-processing: the JS side also resolves `<!-- hwip-branch -->` /
# `<!-- hwip-doc-only -->` blocks. This one does not, so it must only ever be
# aimed at a section that carries none (Rule 9 today) — pointing it at
# `### Push Signal` would leak raw markers into the model's context.
hwip_core_section() {
    local file out
    file="$(dirname "${BASH_SOURCE[0]}")/../docs/CORE_RULES.md"
    [ -f "$file" ] || return 1
    local hashes="${1%% *}"
    out=$(awk -v want="$1" -v depth="${#hashes}" '
        $0 == want { inside = 1; print; next }
        inside && /^#+ / && index($0, " ") - 1 <= depth { exit }
        inside { print }
    ' "$file")
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

# ── Hook id (two-way) resolution ─────────────────────────────────────────────
#
# hwip_hook_id — echoes the two-way hook id, or nothing when the install is
# notify-only. The order is the one hwip-setup.js (`envOr('HWIP_HOOK_ID') ||
# config.hookId`) and the MCP server (`resolvedEnv('HWIP_HOOK_ID') ??
# fileConfig.hookId`) already use: the env var when it carries a real value
# — an unresolved `${HWIP_HOOK_ID}` placeholder forwarded from an .mcp.json
# env block counts as unset — else `hookId` in ~/.hwip/config.json, which
# `hwip setup` writes. Four runtimes, one contract (docs/HOOKS-EXPLAINED.md);
# the shell hooks were the one reader that skipped the file.
#
# Forks `jq` on the config path — call it only on the branch that needs the
# answer, never up front (the hooks that source this run on every prompt).
hwip_hook_id() {
    local id="${HWIP_HOOK_ID:-}"
    case "$id" in '${'*) id="" ;; esac
    if [ -z "$id" ] && [ -n "${HOME:-}" ] && [ -f "$HOME/.hwip/config.json" ]; then
        id=$(jq -r '.hookId // empty' "$HOME/.hwip/config.json" 2>/dev/null)
    fi
    printf '%s' "$id"
}

# ── Reading a time out of a state file ───────────────────────────────────────
#
# Several state files hold an epoch second the hooks wrote themselves. Bash
# arithmetic is where a damaged one hurts: `$(( now - ts ))` reads a leading 0 as
# octal ("value too great for base") and wraps on a number past 63 bits, and an
# arithmetic error ends the command it sits in — in the approval hook that is
# the compound command holding the REMOTE check, whose outcome nobody chose.
# So no hook subtracts a number it has not checked first.
#
# hwip_age_sec <epoch> — echoes how many seconds ago <epoch> was, negative for a
# time ahead of the clock (it was set back, or the file is damaged); rc 1 when it
# is not a plain number of at most 12 digits (year 33658 — anything longer is not
# a time). A leading 0 is read as decimal. Each caller decides what ahead means.
hwip_age_sec() {
    local ts="$1" now
    case "$ts" in ''|*[!0-9]*|?????????????*) return 1 ;; esac
    now=$(hwip_ask_now)
    case "$now" in ''|*[!0-9]*) return 1 ;; esac
    echo $((now - 10#$ts))
}

# ── Sticky REMOTE state ─────────────────────────────────────────────────────
#
# `remote-<hash>` above is a ONE-SHOT entry signal — hwip-remote.sh consumes it
# the moment a prompt matches. REMOTE outlives that turn, so the mode itself
# needs somewhere to live: `remote-active-<hash>`, holding the epoch second it
# was last confirmed. Keeping it in a file (rather than re-deriving it from the
# conversation) is what makes it survive context compaction.
#
# Deliberately NOT routed through hwip_state_present. That helper also honors a
# legacy /tmp copy, which exists so files written by older versions keep working
# — this kind has never had a /tmp writer, so the branch could only ever match
# something stale, and the refresh below always writes the XDG path, so such a
# file would never expire.
#
# The TTL is the backstop, not the usual exit. The named exits — a Done-like
# hwip_ask answer, the model's `<!-- hwip: exit -->`, and a prompt the user
# typed at the terminal — all clear the file outright. What none of them covers
# is a session that simply died (there is no SessionEnd hook), and without a
# TTL a crash or Ctrl-C would latch REMOTE forever, leaving every later session
# in the project asking a phone nobody is holding. Four hours is generous on
# purpose: the file is refreshed on every phone prompt and every answered
# hwip_ask, so it only has to outlive a working session, never an idle user.
# The TS twin is cli/src/gate.ts REMOTE_TTL_SEC.
HWIP_REMOTE_TTL=14400

hwip_remote_state_file() { echo "$HWIP_STATE_DIR/remote-active-$1"; }

# hwip_remote_active <hash> — rc 0 while REMOTE is live for this project.
# Expired or unparseable state is deleted on sight, the same housekeeping a
# stale entry marker gets: state that can never flag again is dead weight.
hwip_remote_active() {
    local file ts age
    file=$(hwip_remote_state_file "$1")
    [ -f "$file" ] || return 1
    read -r ts < "$file" 2>/dev/null || ts=""
    age=$(hwip_age_sec "$ts") || { rm -f "$file"; return 1; }
    if [ "$age" -gt "$HWIP_REMOTE_TTL" ]; then
        rm -f "$file"
        return 1
    fi
    # A time ahead of the clock reads as now, and writing now back makes the TTL
    # count from here: left alone the file would stay live until the clock
    # caught up with it. If now cannot be written (a read-only state folder)
    # nothing would ever end it, so it is not REMOTE, and the file goes if it can.
    # The TS twin is cli/src/gate.ts isRemoteActive.
    if [ "$age" -lt 0 ]; then
        if ! hwip_ask_now 2>/dev/null > "$file"; then
            rm -f "$file" 2>/dev/null
            return 1
        fi
    fi
    return 0
}

# hwip_remote_touch <hash> — enter REMOTE, or push its expiry back. Always rc 0:
# a state dir that cannot be written must never fail the hook that called this.
hwip_remote_touch() {
    mkdir -p "$HWIP_STATE_DIR" 2>/dev/null || return 0
    date +%s > "$(hwip_remote_state_file "$1")" 2>/dev/null || return 0
}

# hwip_remote_clear <hash> — leave REMOTE. Always rc 0, and an absent file is
# success: the callers are hooks that have their own job to finish.
hwip_remote_clear() {
    rm -f "$(hwip_remote_state_file "$1")" 2>/dev/null
    return 0
}

# ── Dangerous-command approval (hwip-approve.sh) ─────────────────────────────
#
# hwip_approve_needed <command> — rc 0 when this command should wait for the
# user's approval, rc 1 when it should just run.
#
# ⚠️ THIS IS A SPEED BUMP, NOT A SECURITY BOUNDARY. It matches text in a command
# string, so anything deliberately trying to get past it will
# (`r''m -rf`, a shell variable, a script that wraps the real call). What it
# actually protects against is the accident: an agent reaching for `rm -rf` or a
# prod deploy while the user is away from the terminal and would never have seen
# the confirmation. Do not describe it as a sandbox, and do not let its presence
# justify loosening anything that is one.
#
# The list is deliberately short. Gating everything trains people to approve
# without reading, which is worse than not gating at all; gating too little is
# theatre. These are the operations that are hard to undo:
#   1. recursive force delete
#   2. history/working-tree destruction (force push, hard reset, clean -fd)
#   3. anything that reaches deployed infrastructure
#   4. destructive database statements
hwip_approve_needed() {
    local cmd="$1"
    [ -n "$cmd" ] || return 1

    # Builtin pre-filter. This runs on EVERY Bash tool call, and without it an
    # ordinary `ls` pays for the whole grep chain below — a dozen forks to
    # conclude nothing matches. Every pattern further down contains one of these
    # keywords, so anything reaching the greps is at least plausible.
    # Written as character classes rather than `shopt -s nocasematch` because
    # gate.sh is SOURCED into the hooks: flipping a shell option here would
    # change matching for the rest of the calling script. Character classes are
    # also bash 3.2 safe (macOS /bin/bash), which `${cmd,,}` is not.
    case "$cmd" in
        *[Rr][Mm]*|*[Gg][Ii][Tt]*|*[Dd][Ee][Pp][Ll][Oo][Yy]*|*[Tt][Ee][Rr][Rr][Aa][Ff][Oo][Rr][Mm]*) ;;
        *[Dd][Rr][Oo][Pp]*|*[Tt][Rr][Uu][Nn][Cc][Aa][Tt][Ee]*|*[Dd][Ee][Ll][Ee][Tt][Ee]*|*[Ff][Ll][Uu][Ss][Hh]*) ;;
        *) return 1 ;;
    esac

    # 1. rm carrying BOTH recursive and force, however they are spelled.
    #    Collapsing every short flag into one string is what makes `-rf`,
    #    `-fr` and `-r -f` the same question instead of three patterns.
    #
    #    The hyphen goes LAST in the tr delete set. Written as ' -\n' it reads
    #    as a RANGE from space (0x20) to newline (0x0A) — reversed, so GNU tr
    #    aborts with "range-endpoints ... in reverse collating sequence order"
    #    and prints nothing. BSD tr takes the same three bytes literally, so on
    #    macOS it worked and on Linux `flags` came back empty and every
    #    `rm -rf` walked straight through this gate.
    if grep -Eqi '(^|[^[:alnum:]_./-])rm[[:space:]]' <<< "$cmd"; then
        local flags
        flags=$(sed -e 's/--recursive/-r/g' -e 's/--force/-f/g' <<< "$cmd" \
            | grep -Eo -- '(^|[[:space:]])-[[:alnum:]]+' \
            | tr -d ' \n-' | tr 'A-Z' 'a-z')
        case "$flags" in *r*f*|*f*r*) return 0 ;; esac
    fi

    # 2. Git operations that discard work or rewrite a published history.
    #    The second push alternative is NOT redundant with the first: `^` anchors
    #    to the start of the whole string, so once `push[[:space:]]` has eaten the
    #    only space, `-f`'s own `(^|[[:space:]])` branch has nothing left to match
    #    and bare `git push -f` slips through. Removing it fails a vector.
    grep -Eqi 'git[[:space:]]+push[[:space:]].*(--force|--force-with-lease|(^|[[:space:]])-f([[:space:]]|$))|git[[:space:]]+push[[:space:]]+-f([[:space:]]|$)|git[[:space:]]+reset[[:space:]]+--hard|git[[:space:]]+clean[[:space:]]+-[[:alnum:]]*[fd]' <<< "$cmd" && return 0

    # 3. Anything that reaches deployed infrastructure. The last alternative is a
    #    package script whose NAME says deploy (`yarn server:deploy:prod`), kept
    #    behind a runner prefix so `grep -rn deploy src/` is not a deploy.
    grep -Eqi '(^|[^[:alnum:]_-])(cdk|serverless|sls)[[:space:]]+deploy|(^|[^[:alnum:]_-])terraform[[:space:]]+(apply|destroy)|(^|[^[:alnum:]_-])(npm[[:space:]]+run|yarn|pnpm[[:space:]]+run|bun[[:space:]]+run)[[:space:]]+[[:alnum:]:_-]*deploy' <<< "$cmd" && return 0

    # 4. Statements that drop data rather than change it.
    grep -Eqi 'drop[[:space:]]+(table|database|schema)|truncate[[:space:]]+table|delete-table|flushall|flushdb' <<< "$cmd" && return 0

    return 1
}

# ── AskUserQuestion replay markers ───────────────────────────────────────────
#
# A deny is only safe if the same question can get through on its next try —
# see `replay` in hwip_ask_decide. These two record and read that fact.
#
# The key must be the whole tool_input, not the question stem: "Proceed?" and
# "Continue?" recur constantly within one session, so hashing the stem would
# make unrelated questions collide and silently allow the second one.
#
# The window separates a retry from a legitimate repeat. A model that cannot
# reach `hwip_ask` retries within seconds; a user genuinely being asked the same
# thing again is minutes away. 60 seconds sits between the two.
#
# The timestamp lives in the file's CONTENTS rather than its mtime: `stat` takes
# different flags on macOS and GNU, and `find -newermt` isn't portable either.
# Reading an integer we wrote ourselves works the same everywhere.
HWIP_ASK_REPLAY_WINDOW_SEC=60

# hwip_ask_now — epoch seconds. Bash 5 has it as a builtin; older bash (macOS
# ships 3.2 as /bin/bash) falls back to the `date` binary.
hwip_ask_now() {
    if [ -n "${EPOCHSECONDS:-}" ]; then
        echo "$EPOCHSECONDS"
    else
        date +%s
    fi
}

# hwip_ask_replay_seen <key> — rc 0 when this question was denied recently.
#
# `key` is project-scoped by the caller, matching how every other state file
# here is keyed (`muted-<project>`, `pushmode-<project>`). Keying on the
# question alone would let a deny in one project allow the identical question
# in another — two sessions asking "Proceed?" within the window is ordinary.
hwip_ask_replay_seen() {
    local file="$HWIP_STATE_DIR/askdeny-$1" stamp age
    stamp=$(cat "$file" 2>/dev/null) || return 1
    age=$(hwip_age_sec "$stamp") || return 1
    # A stamp from the future is not a recent denial; the sweep drops it.
    [ "$age" -ge 0 ] && [ "$age" -lt "$HWIP_ASK_REPLAY_WINDOW_SEC" ]
}

# hwip_ask_replay_mark <key> — record that this question was just denied, and
# drop markers that have aged out.
#
# The sweep matters: every denied question leaves a file, and a marker is dead
# to `hwip_ask_replay_seen` the moment its window closes. Without it the state
# dir accretes one file per question forever. It runs here rather than on a
# timer because this is the only place that creates them, and the expiry test
# is the same integer compare — no `stat`, no `find -newermt`.
#
# Best-effort throughout: a state dir we cannot write means the next retry is
# denied too, which would trap that one session. That is worth neither failing
# the hook nor blocking on.
hwip_ask_replay_mark() {
    mkdir -p "$HWIP_STATE_DIR" 2>/dev/null || return 0
    local file stamp age
    for file in "$HWIP_STATE_DIR"/askdeny-*; do
        [ -f "$file" ] || continue
        read -r stamp < "$file" 2>/dev/null || stamp=""
        age=$(hwip_age_sec "$stamp") || { rm -f "$file" 2>/dev/null; continue; }
        if [ "$age" -lt 0 ] || [ "$age" -ge "$HWIP_ASK_REPLAY_WINDOW_SEC" ]; then rm -f "$file" 2>/dev/null; fi
    done
    printf '%s\n' "$(hwip_ask_now)" > "$HWIP_STATE_DIR/askdeny-$1" 2>/dev/null || true
}

# Bounding a CLI invocation (hwip_bound_prefix, hwip_wrap_timeout,
# hwip_cli_command below) under the calling
# hook's cap in plugin.json, so a cold `npx -y` resolve or a hung network can't
# eat the whole hook budget. macOS ships no `timeout` in the base system
# (gtimeout comes from coreutils), so stock macOS — the main platform — falls
# back to perl, which macOS does ship. Only with none of the three is the
# plugin.json cap the only bound. A `timeout` that is not GNU (Windows Git
# Bash's native `timeout.exe`) counts as absent — see hwip_timeout_is_gnu.
#
# The bound is a parameter because the two callers have very different budgets:
# the ask hook has 10s and wants 8, while the approval hook deliberately waits
# on a human for over a minute. A single hardcoded 8 would have made the
# approval gate unwrappable — and an unwrapped CLI call there is not a slow
# hook, it is a SILENT ALLOW of the exact commands the gate exists to hold,
# because Claude Code fails open when it kills a hook.
#
# The perl fallback matches GNU timeout on these points: the command runs in
# its own process group, the whole group gets SIGTERM at the bound (so an npx
# grandchild holding stdout can't keep $(...) waiting), and the exit code is
# 124 on timeout, 125 when it cannot start the command (fork failed — running
# it unbounded would be the silent allow again), otherwise the command's own
# (128+N when a signal killed it). Checked 2026-10-01: /usr/bin/perl is 5.34 on
# macOS 15, and coreutils timeout(1) signals the whole group unless --foreground.
# It does not pass on a TERM or INT sent to perl itself: killing only the
# wrapper ends the alarm with it and leaves the command running unbounded.
# hwip_wrap_timeout's callers word-split the result, so the program is one word: no spaces and no
# glob characters (`*`, `?`, `[`) — hence ${^CHILD_ERROR_NATIVE} over `$?`.
HWIP_PERL_TIMEOUT='setpgrp(0,0);$t=shift;defined($p=fork)||exit(125);if(!$p){exec(@ARGV);exit(127)}$SIG{ALRM}=sub{$SIG{TERM}="IGNORE";kill("TERM",-$$);exit(124)};alarm($t);waitpid($p,0);$s=${^CHILD_ERROR_NATIVE};exit(($s&127)&&128+($s&127)||$s>>8)'
# hwip_timeout_is_gnu — rc 0 when `timeout` on PATH runs `timeout <secs> <cmd>`.
# Windows Git Bash also exposes a native `timeout.exe` (a wait, `timeout /t` —
# it runs no command) under the same name (P30). GNU coreutils answers --version
# (checked on macOS Homebrew coreutils). Unverified (no Windows or BusyBox machine
# at hand, 2026-10-14): that BusyBox answers --help, and that the native one
# answers neither — Git for Windows usually puts /usr/bin (coreutils) ahead of
# System32, so that case may never arise. Probed, not assumed — the name alone
# cannot tell them apart.
hwip_timeout_is_gnu() {
    timeout --version >/dev/null 2>&1 || timeout --help >/dev/null 2>&1
}
# hwip_bound_prefix [seconds] — HWIP_BOUND, an array: the words that bound the
# command after them (`timeout 8`, `gtimeout 8`, `perl -e … 8`), empty when the
# machine has none of the three.
hwip_bound_prefix() {
    local seconds="${1:-8}"
    if command -v timeout >/dev/null 2>&1 && hwip_timeout_is_gnu; then
        HWIP_BOUND=(timeout "$seconds")
    elif command -v gtimeout >/dev/null 2>&1; then
        HWIP_BOUND=(gtimeout "$seconds")
    elif command -v perl >/dev/null 2>&1; then
        HWIP_BOUND=(perl -e "$HWIP_PERL_TIMEOUT" "$seconds")
    else
        HWIP_BOUND=()
    fi
}

# hwip_wrap_timeout <cmd> [seconds] — the bounded command line as ONE STRING for
# a caller that word-splits it. Only for a fixed program name (`tmux`, `ioreg`):
# anything found on PATH can hold a space, and goes through hwip_cli_command.
hwip_wrap_timeout() {
    hwip_bound_prefix "${2:-8}"
    if [ "${#HWIP_BOUND[@]}" -gt 0 ]; then echo "${HWIP_BOUND[*]} $1"; else echo "$1"; fi
}

# hwip_probe_cmd <cmd> — hwip_wrap_timeout <cmd> 2 for one presence probe, also held to
# HWIP_PROBE_DEADLINE: the `$SECONDS` reading after which no probe may start (the Stop hook
# sets it; unset, as in the approval hook, there is only the 2 s bound per call). A probe
# gets min(2, the whole seconds left), and once none are left the command is `false`: it
# runs, fails at once and answers nothing — the same as a tmux that never answered, which
# every caller already reads as unknown. `$SECONDS` counts whole wall-clock seconds, so
# "left" is off by up to one second; the deadline is picked with that slack.
hwip_probe_cmd() {
    local bound=2 left
    if [ -n "${HWIP_PROBE_DEADLINE:-}" ]; then
        left=$((HWIP_PROBE_DEADLINE - SECONDS))
        [ "$left" -ge 1 ] || { echo false; return 0; }
        [ "$left" -lt "$bound" ] && bound=$left
    fi
    hwip_wrap_timeout "$1" "$bound"
}

# hwip_cli_command [seconds] — HWIP_CLI, an ARRAY: the bounded command line that
# starts the Hwip CLI. Call it as `"${HWIP_CLI[@]}" notify --title=…`. The CLI is
# `hwip` when it is on PATH, else `npx -y @hwip/cli` (three words). It used to be
# one string that the hooks left unquoted, so a `hwip` under `/Users/Jane Doe/…`
# split into two words and the CLI was never started: no push, and an approval
# that could only be denied.
hwip_cli_command() {
    local bin
    if bin=$(command -v hwip 2>/dev/null) && [ -n "$bin" ]; then
        HWIP_CLI=("$bin")
    else
        HWIP_CLI=(npx -y @hwip/cli)
    fi
    hwip_bound_prefix "${1:-8}"
    HWIP_CLI=(${HWIP_BOUND[@]+"${HWIP_BOUND[@]}"} "${HWIP_CLI[@]}")
}

# ── Presence: is the user away from the terminal? ────────────────────────────
#
# hwip_presence — echoes away, present or unknown. `present` and `away` need a
# probe that answered; anything unreadable is `unknown`.
# hwip_is_away — rc 0 when the user looks away from THIS session, rc 1 when
# present or when presence cannot be read. The quiet dial silences routine
# pushes because the user is watching the pane; an away user is not, so the
# Stop hook passes this to hwip_gate_decide as `away`. Away is the machine
# verdict below, or this session's tmux pane being hidden (hwip_pane_visible):
# a keyboard or a tmux client says the user is at the desk, not that they are
# looking at this session. The TS twin is cli/src/presence.ts isAway — keep the
# probe order and fallbacks behaviorally in sync.
#
# Threshold: HWIP_AWAY_SEC seconds (default 300, `0` disables, anything that is
# not a whole number of at most 9 digits falls back to the default — longer ones
# would overflow `[ -gt ]`). Probes, first answer wins:
#   1. inside tmux and no client attached to the server at all → away. Any
#      attached client means someone is at a tmux terminal — switching the one
#      client between sessions does not make the machine read as away (the
#      pane check in hwip_is_away still asks about this session).
#   2. not over SSH and ioreg reports HIDIdleTime (macOS) → that decides, and
#      nothing below runs: tmux activity only sees keys typed into tmux, so a
#      user reading a browser would look idle to it. Inside tmux, "over SSH"
#      comes from the session environment (`show-environment`), which tmux
#      refreshes on every attach — the process's own SSH_CONNECTION is frozen
#      at server start and misreads a local server someone attached to over
#      SSH, or the reverse.
#   3. inside tmux → the newest client_activity, i.e. the last key any tmux
#      client received (SSH and non-macOS hosts land here).
# Anything else is unknown — including a probe the Stop hook's deadline skips or cuts
# (HWIP_PROBE_DEADLINE, hwip_probe_cmd). hwip_is_away reads unknown as present — an
# unreadable signal must never add a push — while the approval hook reads it as
# "maybe nobody is watching" and keeps asking the phone; each caller picks the
# safe side for itself.
# hwip_away_threshold — HWIP_AWAY_SEC as a whole number of seconds, 300 when it
# is not one; `0` means detection is off.
hwip_away_threshold() {
    local threshold="${HWIP_AWAY_SEC:-300}"
    case "$threshold" in ''|*[!0-9]*|??????????*) threshold=300 ;; esac
    echo "$threshold"
}

hwip_presence() {
    local threshold
    threshold=$(hwip_away_threshold)
    [ "$threshold" -gt 0 ] || { echo unknown; return 0; }

    local in_tmux=0 activity="" idle_ns=""
    if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
        # rc ≠ 0 = no server answered; an empty list = a server with no clients.
        if activity=$($(hwip_probe_cmd tmux) list-clients -F '#{client_activity}' 2>/dev/null); then
            [ -z "$activity" ] && { echo away; return 0; }
            in_tmux=1
        fi
    fi

    local over_ssh=0 ssh_var
    if [ "$in_tmux" = 1 ] \
        && ssh_var=$($(hwip_probe_cmd tmux) show-environment SSH_CONNECTION 2>/dev/null); then
        case "$ssh_var" in SSH_CONNECTION=*) over_ssh=1 ;; esac
    elif [ -n "${SSH_CONNECTION:-}" ]; then
        over_ssh=1
    fi

    if [ "$over_ssh" = 0 ] && command -v ioreg >/dev/null 2>&1; then
        # -r -k -d 1 prints just the IOHIDSystem node (~4 KB) instead of its
        # whole subtree (~380 KB) — measured 17 ms vs 29 ms on 2026-09-11.
        idle_ns=$($(hwip_probe_cmd ioreg) -r -k HIDIdleTime -d 1 -c IOHIDSystem 2>/dev/null \
            | awk '/HIDIdleTime/ {print $NF; exit}')
        # At most 18 digits (ns idle fits 63 bits long before that) and read as
        # decimal: anything else is not an answer and the probes below decide.
        case "$idle_ns" in
            ''|*[!0-9]*|???????????????????*) ;;
            *)
                if [ $(( 10#$idle_ns / 1000000000)) -ge "$threshold" ]; then echo away; else echo present; fi
                return 0 ;;
        esac
    fi

    [ "$in_tmux" = 1 ] || { echo unknown; return 0; }
    local line newest=""
    while IFS= read -r line; do
        case "$line" in ''|*[!0-9]*) continue ;; esac
        { [ -z "$newest" ] || [ "$line" -gt "$newest" ]; } && newest=$line
    done <<< "$activity"
    [ -n "$newest" ] || { echo unknown; return 0; }
    local idle_sec
    idle_sec=$(hwip_age_sec "$newest") || { echo unknown; return 0; }
    if [ "$idle_sec" -ge "$threshold" ]; then echo away; else echo present; fi
}

hwip_is_away() {
    # `0` turns the whole detection off, the pane check included.
    [ "$(hwip_away_threshold)" -gt 0 ] || return 1
    [ "$(hwip_presence)" = away ] || [ "$(hwip_pane_visible)" = hidden ]
}

# hwip_pane_visible — echoes hidden, visible or unknown for THIS session's tmux
# pane. hwip_presence is the machine's: a keyboard or a tmux client says the
# user is at the desk, not which tmux session they are looking at, so a session
# in a window nobody has up read as `present` and could wait on a terminal prompt
# nobody saw. Used by the approval hook (hwip-approve.sh), which holds a command
# until a person answers, and by hwip_is_away, so a completion push on the quiet
# dial reaches a user who is not looking at this session (the cli's twin,
# presence.ts, does the same).
#
# Asks tmux about $TMUX_PANE: `#{session_attached}` (clients on its session),
# `#{window_active}` (its window is the session's current one), `#{pane_active}`
# and `#{window_zoomed_flag}` (a different pane zoomed over it hides it; a split
# pane that is merely not the active one is still on screen). A control-mode
# client (iTerm2 `tmux -CC`) makes a non-current window look hidden while it is on
# screen, so one attached anywhere reads as unknown; so does a window linked into
# several sessions, which tmux reports for just one of them (not detected). Anything short of
# a plain answer — not in tmux, no TMUX_PANE, tmux silent or slow, output that
# is not four numbers — is `unknown`: no narrowing, the machine verdict stands,
# so a tmux that will not answer cannot turn every at-the-desk approval into a
# phone round trip.
hwip_pane_visible() {
    if [ -z "${TMUX:-}" ] || [ -z "${TMUX_PANE:-}" ] || ! command -v tmux >/dev/null 2>&1; then
        echo unknown; return 0
    fi
    local facts attached win_active pane_active zoomed
    facts=$($(hwip_probe_cmd tmux) display-message -p -t "$TMUX_PANE" \
        '#{session_attached} #{window_active} #{pane_active} #{window_zoomed_flag}' 2>/dev/null) \
        || { echo unknown; return 0; }
    read -r attached win_active pane_active zoomed <<< "$facts"
    # Each field on its own: an empty one shifts the rest left in `read`, and a
    # joined check would still see digits.
    local f
    for f in "$attached" "$win_active" "$pane_active" "$zoomed"; do
        case "$f" in '' | *[!0-9]*) echo unknown; return 0 ;; esac
    done
    if [ "$attached" -eq 0 ] || [ "$win_active" -eq 0 ] || { [ "$zoomed" -ne 0 ] && [ "$pane_active" -eq 0 ]; }; then
        # A control-mode client (iTerm2 `tmux -CC`) shows every window as its own
        # native tab or window, so a window that is not the session's current one
        # can still be on screen. Read as unknown, never as hidden.
        # Under the Stop hook's deadline (HWIP_PROBE_DEADLINE) this probe may be skipped,
        # or time out on a tmux that is already slow — that is no verdict: `hidden` would
        # add a push on no evidence.
        local probe clients rc
        probe=$(hwip_probe_cmd tmux)
        [ "$probe" != false ] || { echo unknown; return 0; }
        clients=$($probe list-clients -F '#{client_control_mode}' 2>/dev/null); rc=$?
        [ "$rc" -ne 124 ] || [ -z "${HWIP_PROBE_DEADLINE:-}" ] || { echo unknown; return 0; }
        if grep -qx 1 <<< "$clients"; then echo unknown; return 0; fi
        echo hidden
    else
        echo visible
    fi
}
