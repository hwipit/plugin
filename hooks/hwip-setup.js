#!/usr/bin/env node
'use strict';

// SessionStart hook — injects Hwip's rules into the session as
// hookSpecificOutput.additionalContext, so they land in Claude's context and
// not just the user's transcript.
//
// STATE-CONDITIONAL, and it has to be. Claude Code persists a hook's
// additionalContext to a file the moment it exceeds 10,000 chars and replaces
// it with a 2,000-char preview (cli.js: `Pyt(e,t,r,n=k$d)`, `k$d=1e4`,
// preview `hFr=2000`). The unconditional full text was 15,483 bytes, so every
// rule below the first 2KB — the whole Ask Loop, sticky REMOTE, the
// AskUserQuestion override — never reached the model at all. Shrinking the
// text is therefore not an optimisation; it is what makes the rules exist.
//
// The hook already knows the state it is injecting into, so it reads it and
// emits that branch only:
//
//   muted        → three lines; the hooks are silent anyway
//   no hookId    → one-way notify discipline; hwip_ask does not exist
//   REMOTE       → sticky REMOTE in full, no Push Signal (REMOTE ignores markers)
//   NORMAL       → the default branch, with a two-line pointer to REMOTE
//
// A session that transitions into REMOTE on a phone message gets the full
// contract from the UserPromptSubmit hook (hooks/hwip-remote.sh) on that turn.
// Any state read that fails resolves to the NORMAL branch.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync, execSync } = require('child_process');
const { readLastPushFailure, describeLastPushFailure, takeKeyChanges, describeKeyChange } = require('./notify-failure');

const configFile = path.join(os.homedir(), '.hwip', 'config.json');
let config = {};
try { config = JSON.parse(fs.readFileSync(configFile, 'utf-8')); } catch {}

const envOr = (key) => {
    const v = process.env[key];
    if (!v) return undefined;
    if (v.startsWith('${')) return undefined; // unresolved ${VAR} placeholder
    if (v.length === 0) return undefined;
    return v;
};

const apiKey = envOr('HWIP_API_KEY') || config.apiKey;
const hookId = envOr('HWIP_HOOK_ID') || config.hookId;

const hasJq = (() => {
    try { execSync('command -v jq', { stdio: 'pipe' }); return true; } catch { return false; }
})();

// additionalContext reaches only the model. systemMessage is what the user sees
// in the Claude Code UI, so the states that silence the plugin (not configured,
// muted, no jq) say so there too instead of failing quietly — and so does the
// CLI's record of its last failed push, whatever the state.
const emit = (additionalContext, systemMessage) => {
    process.stdout.write(JSON.stringify({
        ...(systemMessage ? { systemMessage } : {}),
        hookSpecificOutput: {
            hookEventName: 'SessionStart',
            additionalContext,
        },
    }));
};

if (!apiKey) {
    emit(
        '# System note (Hwip plugin — internal, do not surface unless asked)\n\n' +
        'Hwip is installed but not configured. The user can run ' +
        '`npx @hwip/cli setup` to enable cross-device notifications and remote control. ' +
        'Until configured, do NOT call any hwip_* MCP tools.',
        'Hwip is not configured, so no notifications will be sent. Run `npx @hwip/cli setup` to set it up.'
    );
    process.exit(0);
}

// ── State ───────────────────────────────────────────────────────────────────
//
// The JS twin of hooks/gate.sh's state resolution — same paths, same legacy
// /tmp ownership check, same TTL, same push-mode fallbacks. Kept in one
// try/catch: an unreadable state dir must resolve to the NORMAL branch, never
// to "emit everything" (which is the failure this rewrite exists to remove).

const STATE_DIR = path.join(process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state'), 'hwip');
const REMOTE_TTL_SEC = 14400;
const PUSHMODE_DEFAULT = 'quiet';

// The directory every shell hook hashes: ${CLAUDE_PROJECT_DIR:-$PWD}. Without
// CLAUDE_PROJECT_DIR the shell side reads bash's $PWD — the inherited one,
// symlinked path and all, when it still names the working directory, else the
// physical path. process.cwd() is always the physical path, so under a
// symlinked cwd the two used to hash different strings and this hook read none
// of the mute / dial / REMOTE state the others wrote. Asked of bash itself,
// shelled out like cksum below: its rules differ between versions (3.2 keeps
// `./` components, 5 normalizes), and a reimplementation would split on those.
const projectDir = () => {
    if (process.env.CLAUDE_PROJECT_DIR) return process.env.CLAUDE_PROJECT_DIR;
    try {
        const pwd = execFileSync('bash', ['-c', 'printf %s "$PWD"'], { encoding: 'utf-8' });
        if (pwd) return pwd;
    } catch {}
    return process.cwd();
};

// cksum of the project dir, exactly as every shell hook computes it — shelled
// out rather than reimplemented so the two can never disagree on a hash.
const projectHash = () =>
    execSync('cksum', { input: projectDir(), encoding: 'utf-8' }).trim().split(/\s+/)[0];

// gate.sh hwip_state_present: XDG path, then a legacy /tmp copy but only when
// the current user owns it (a planted file must not be able to mute someone).
const statePresent = (kind, hash) => {
    const xdg = path.join(STATE_DIR, `${kind}-${hash}`);
    if (fs.existsSync(xdg)) return xdg;
    const legacy = `/tmp/hwip-${kind}-${hash}`;
    try {
        if (fs.statSync(legacy).uid === process.getuid()) return legacy;
    } catch {}
    if (kind === 'pushmode') {
        const fallback = path.join(STATE_DIR, 'pushmode-default');
        if (fs.existsSync(fallback)) return fallback;
    }
    return null;
};

// gate.sh hwip_remote_active. Deliberately no /tmp branch (that kind never had
// a /tmp writer) and the TTL is enforced here too — without it a crashed
// session would latch the REMOTE branch for every later session in the project.
const remoteActive = (hash) => {
    const file = path.join(STATE_DIR, `remote-active-${hash}`);
    let ts;
    try { ts = fs.readFileSync(file, 'utf-8').split('\n')[0].trim(); } catch { return false; }
    if (!/^\d+$/.test(ts)) return false;
    return Math.floor(Date.now() / 1000) - Number(ts) <= REMOTE_TTL_SEC;
};

// gate.sh hwip_read_pushmode: no hash → normal, no dial file → quiet,
// empty/garbage → normal.
const readPushmode = (hash) => {
    if (!hash) return 'normal';
    const file = statePresent('pushmode', hash);
    if (!file) return PUSHMODE_DEFAULT;
    let mode = '';
    try { mode = fs.readFileSync(file, 'utf-8').replace(/\s/g, ''); } catch {}
    return ['quiet', 'loud', 'normal'].includes(mode) ? mode : 'normal';
};

const readState = () => {
    try {
        const hash = projectHash();
        return { muted: !!statePresent('muted', hash), remote: remoteActive(hash), pushmode: readPushmode(hash) };
    } catch (err) {
        process.stderr.write(`[hwip-setup] state unreadable, falling back to NORMAL: ${err.message}\n`);
        return { muted: false, remote: false, pushmode: 'normal' };
    }
};

// ── CORE_RULES.md slicing ───────────────────────────────────────────────────

let coreRules = '';
try {
    coreRules = fs.readFileSync(path.join(__dirname, '..', 'docs', 'CORE_RULES.md'), 'utf-8');
} catch (err) {
    // Surface the real cause on stderr so a broken install is visible, not silent.
    process.stderr.write(`[hwip-setup] Could not read docs/CORE_RULES.md: ${err.message}\n`);
    coreRules = `# Hwip — Remote-Control Rules

Unable to load Hwip rules from plugin/docs/CORE_RULES.md — the plugin may be
corrupted or partially installed. Reinstall with:
  claude plugin uninstall hwip@hwip && claude plugin marketplace add hwipit/plugin`;
}

// One `###`/`####` section, heading included, up to the next heading of the
// same or a higher level. Missing heading → empty string: a rename in
// CORE_RULES.md must drop one section, not crash the session's first turn.
const section = (heading) => {
    const level = heading.match(/^#+/)[0].length;
    const lines = coreRules.split('\n');
    const start = lines.findIndex((l) => l.trim() === heading);
    if (start === -1) return '';
    let end = lines.length;
    for (let i = start + 1; i < lines.length; i++) {
        const m = lines[i].match(/^(#+) /);
        if (m && m[1].length <= level) { end = i; break; }
    }
    return lines.slice(start, end).join('\n').replace(/\n+---\s*$/, '').trim();
};

// Resolve the `<!-- hwip-branch: NAME -->` blocks a section carries: keep the
// one that matches this session's state, drop the rest and every marker.
// `<!-- hwip-doc-only -->` blocks explain the branching to a human reading
// CORE_RULES.md and are never injected.
const pickBranch = (text, keep) => text
    .replace(/<!-- hwip-branch: ([\w-]+) -->\n([\s\S]*?)\n<!-- \/hwip-branch -->\n?/g,
        (_, name, body) => (name === keep ? `${body}\n` : ''))
    .replace(/<!-- hwip-doc-only -->\n[\s\S]*?\n<!-- \/hwip-doc-only -->\n?/g, '')
    .replace(/\n{3,}/g, '\n\n')
    .trim();

const pushSignal = (pushmode) => pickBranch(
    section('### Push Signal — steer the end-of-turn auto-push (Stop hook)'),
    pushmode === 'quiet' ? 'pushmode-quiet' : 'pushmode-normal-loud'
);

// ── Branches ────────────────────────────────────────────────────────────────

const join = (parts) => parts.filter(Boolean).join('\n\n');

const MUTED = `# Hwip — muted for this project

Push notifications are muted here, so the Stop and Ask hooks stay silent. The \`hwip_*\` MCP tools still work, but do NOT call them unless the user explicitly asks.

\`/hwip-mode unmute\` lifts it.`;

const oneWay = (pushmode) => {
    const body = coreRules.slice(coreRules.indexOf('## One-Way Mode'), coreRules.indexOf('## Environment Notes'))
        .replace(/^## One-Way Mode[^\n]*\n/, '')
        .replace(/\n+---\s*$/, '');
    return `# Hwip — Notification Rules (active every response)\n\n${pickBranch(body, pushmode === 'quiet' ? 'pushmode-quiet' : 'pushmode-normal-loud')}`;
};

// The NORMAL branch owes no `hwip_ask` at all, so it does not carry Rules
// 3/4/5/6/10/11 — every one of them is REMOTE-scoped. What it needs is the
// trigger: what flips the session, and what that turns on. The turn a phone
// message arrives, the UserPromptSubmit hook injects Rule 9 in full from
// CORE_RULES.md; a `hwip_ask` answer that reports `hwipState: "REMOTE"` flips
// it mid-turn, which is why the obligation is stated here rather than pointed at.
const REMOTE_STUB = `### What starts REMOTE

The user sending a message from their phone starts sticky REMOTE — the UserPromptSubmit hook says so on that turn and injects the contract in full. A \`hwip_ask\` result reporting \`hwipState: "REMOTE"\` starts it mid-turn.

From that response on: end EVERY response with \`hwip_ask\` (2–4 \`actions\` plus a Done-like \`fallback\`, \`timeout\` 300–600s), route button-friendly questions through it instead of \`AskUserQuestion\`, and never end on a plain-text question — until the user exits with a Done-like button, the phone's "send and exit" (a result with a \`value\` and \`hwipState: "NORMAL"\` — their final instruction: carry it out, no \`hwip_ask\`), a free-text wrap-up you read as one (emit \`<!-- hwip: exit -->\` once), or a prompt they type at the terminal.`;

const normal = (pushmode) => join([
    '# Hwip — Notification Rules (active every response)',
    '## NORMAL — the user is at the terminal',
    'Hwip can hand this session to the user\'s phone, but nobody has done that yet. **You owe no `hwip_ask`**: ask questions with `AskUserQuestion` or in prose, and let the Stop hook\'s push be the completion signal. A `hwip_ask` here blocks the turn until someone answers on a device or it times out.',
    section('### Notification discipline'),
    pushSignal(pushmode),
    section('### Handling the response'),
    REMOTE_STUB,
    section('### Persistence'),
]);

// No Push Signal here: the markers are ignored on any turn that already sent
// `hwip_ask`, and in REMOTE every turn does. Rules 4/5/6 are likewise left out
// — Rule 9 supersedes Rule 4 while REMOTE holds, and the `actions` requirement
// it turns on is restated inside the sticky-REMOTE text itself.
const remote = () => join([
    '# Hwip — Remote-Control Rules (active every response)',
    '## Two-Way Mode — **this session is in REMOTE**',
    "The user is driving this session from their phone and is NOT at the terminal. Buttons sent via `hwip_ask` are how they steer you; a plain-text question is invisible to them.",
    section('### Notification discipline'),
    section('### When hwip_ask is MANDATORY'),
    section('### Handling the response'),
    section('### Sticky REMOTE mode (Rule 9)'),
    section('### When to use AskUserQuestion vs hwip_ask'),
    section('### Persistence'),
]);

// ── Emit ────────────────────────────────────────────────────────────────────

const state = readState();

// ── "Rule 9 given" mark ─────────────────────────────────────────────────────
// hooks/hwip-remote.sh sends a short reminder instead of the full sticky-REMOTE
// contract to a session marked `remote-injected-<session_id>` (see its header).
// Whether a session holds the full text is decided here too: every SessionStart
// (startup, resume, clear, compact) drops the mark, because compaction and a
// fresh context lose the text, and sets it again only when THIS hook ships the
// REMOTE contract in full. Marks of sessions long gone are pruned on the way.
const INJECTED_PREFIX = 'remote-injected-';
const INJECTED_MAX_AGE_MS = 7 * 24 * 3600 * 1000;

const readSessionId = () => {
    try {
        if (process.stdin.isTTY) return '';
        const id = JSON.parse(fs.readFileSync(0, 'utf-8')).session_id;
        return typeof id === 'string' && /^[A-Za-z0-9_-]+$/.test(id) ? id : '';
    } catch { return ''; }
};

const injectedMarks = () => {
    try { return fs.readdirSync(STATE_DIR).filter((n) => n.startsWith(INJECTED_PREFIX)); } catch { return []; }
};

// Each step is its own best-effort: a failed prune (two starts racing for the
// same old mark) must not keep this session's own stale mark from being removed.
const attempt = (fn) => { try { fn(); } catch { /* no mark just means the full text goes out again */ } };

const syncInjectedMark = (sessionId, shipsFullRemote) => {
    // No readable session id: the mark cannot be addressed, so none may survive —
    // a kept one would leave some session holding a reminder with no full text.
    if (!sessionId) {
        for (const name of injectedMarks()) attempt(() => fs.rmSync(path.join(STATE_DIR, name), { force: true }));
        return;
    }
    const mark = path.join(STATE_DIR, INJECTED_PREFIX + sessionId);
    attempt(() => fs.rmSync(mark, { force: true }));
    if (shipsFullRemote) {
        attempt(() => {
            fs.mkdirSync(STATE_DIR, { recursive: true });
            fs.writeFileSync(mark, '');
        });
    }
    for (const name of injectedMarks()) {
        attempt(() => {
            const file = path.join(STATE_DIR, name);
            if (Date.now() - fs.statSync(file).mtimeMs > INJECTED_MAX_AGE_MS) fs.unlinkSync(file);
        });
    }
};

// Marked only when Rule 9 really goes out: an unreadable CORE_RULES.md makes
// section() return '' and remote() would ship the contract without it.
syncInjectedMark(
    readSessionId(),
    !state.muted && !!hookId && state.remote && section('### Sticky REMOTE mode (Rule 9)') !== '',
);

// The CLI's record of its last failed push (hooks/notify-failure.js). The
// hooks discard notify's stderr, so this is the only place a revoked key or a
// used-up quota surfaces before the user wonders why nothing arrives.
// Devices whose key changed are taken (and the record deleted) only here, as
// the message is built: every path that builds one shows it to the user.
const lastFailure = readLastPushFailure();
const userMessage = (...lines) =>
    [...lines, lastFailure && describeLastPushFailure(lastFailure), ...takeKeyChanges().map(describeKeyChange)]
        .filter(Boolean).join('\n') || undefined;

if (state.muted) {
    // No jq note: a muted project's hooks are silent by design.
    emit(MUTED, userMessage('Hwip is muted for this project. Run `/hwip-mode unmute` to turn notifications back on.'));
    process.exit(0);
}

const rules = !hookId ? oneWay(state.pushmode)
    : state.remote ? remote()
    : normal(state.pushmode);

// Without jq the four shell hooks (Stop, Ask, Approve, UserPromptSubmit) exit
// early and send nothing — which also means the REMOTE full text never arrives.
// The user sees the systemMessage; the model gets the same fact as context.
const jqWarning =
    '\n\n## Environment note\n\n`jq` is not installed on this machine, so the ' +
    'Hwip shell hooks exit early: no pushes, and no remote-mode notes. The user has ' +
    'been shown the install command; mention it again only if they ask about Hwip.';
const jqMessage =
    'Hwip needs `jq`, which is not installed, so no notifications will be sent. ' +
    'Install it with `brew install jq` (macOS) or `apt install jq` (Linux).';

const mode = hookId ? 'two-way (notify + ask)' : 'one-way (notify only)';

emit(`${rules}\n\nMode: ${mode}${hasJq ? '' : jqWarning}`, userMessage(hasJq ? undefined : jqMessage));
