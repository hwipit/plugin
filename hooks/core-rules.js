'use strict';

// CORE_RULES.md slicing, shared by the hooks that inject from it: SessionStart
// (hwip-setup.js) and the PostToolUse hook on hwip_ask (hwip-ask-result.js).
// One reader, so both hand the model the same text for the same heading.

const fs = require('fs');
const os = require('os');
const path = require('path');
const tty = require('tty');

const CORE_RULES_PATH = path.join(__dirname, '..', 'docs', 'CORE_RULES.md');

// Throws when the file cannot be read — callers decide what a missing file
// means for them, and can report the real cause.
const readCoreRules = () => fs.readFileSync(CORE_RULES_PATH, 'utf-8');

// One `###`/`####` section, heading included, up to the next heading of the
// same or a higher level. Missing heading → empty string: a rename in
// CORE_RULES.md must drop one section, not crash the session's first turn.
const section = (coreRules, heading) => {
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

// Rules 7·8. NORMAL's SessionStart text leaves them out; hwip-ask-result.js
// hands them over with the first hwip_ask result of a session context.
const HANDLING_HEADING = '### Handling the response';

// Per-session marks live beside the rest of the hook state. A session id is
// used in a file name only when it is a plain token.
const STATE_DIR = path.join(process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state'), 'hwip');
const SAFE_SESSION_ID = /^[A-Za-z0-9_-]+$/;
const HANDLING_MARK_PREFIX = 'handling-injected-';
// What a handling mark holds says who wrote it: SessionStart when it shipped
// the REMOTE contract (holds until the next start), or the ask hook (ages out).
const HANDLING_MARK_BY_SESSION_START = 'session-start';

// The hook input on stdin, read whole and blocking — for hooks only Claude Code
// runs, which always pipes the input and closes it. An exit before the writer
// finishes hands it a SIGPIPE (tests/test-stdin-drain.sh). Unreadable or not
// JSON → {}. tty.isatty, not process.stdin.isTTY: touching process.stdin turns
// a piped fd 0 non-blocking, and readFileSync(0) then fails with EAGAIN.
// hwip-setup.js keeps its own non-blocking read: scripts/hwip-mode.sh runs it
// with the caller's stdin, which may never close.
const readHookInput = () => {
    try {
        if (tty.isatty(0)) return {};
        return JSON.parse(fs.readFileSync(0, 'utf-8')) || {};
    } catch { return {}; }
};

// A session id usable in a mark file name, else ''.
const sessionIdOf = (input) =>
    (typeof input.session_id === 'string' && SAFE_SESSION_ID.test(input.session_id) ? input.session_id : '');

module.exports = {
    readCoreRules, section, pickBranch, HANDLING_HEADING,
    STATE_DIR, SAFE_SESSION_ID, HANDLING_MARK_PREFIX, HANDLING_MARK_BY_SESSION_START, readHookInput, sessionIdOf,
};
