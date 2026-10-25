#!/usr/bin/env node
'use strict';

// PostToolUse hook on hwip_ask — hands rules 7·8 ("Handling the response") to
// the model with the first hwip_ask result of a session context.
//
// The rules govern only a hwip_ask answer, so NORMAL's SessionStart text leaves
// them out (hwip-setup.js `normal()`) and this hook supplies them when they
// first matter. Claude Code attaches the hook's additionalContext to the tool
// result, and when the call outlives 120s and moves to the background, to the
// background-move result — so the rules land before the answer either way.
//
// Once per session context, by the mark `handling-injected-<sid>`:
//   - hwip-setup.js drops it on every SessionStart (startup, resume, clear,
//     compact), and writes it when it ships the REMOTE contract, which carries
//     these rules already; that mark holds until the next start
//   - this hook writes it after the rules went out; that mark holds for
//     ASK_MARK_TTL_MS only, since /rewind or a restore can drop the result that
//     carried the rules without any SessionStart to say so
//   - a subagent's call (input carries agent_id) neither reads nor writes it:
//     the rules land in the subagent's context, not the main one
// Everything else fails open — a duplicate costs a few hundred chars, a missing
// rule changes what the model does with the user's answer.

const fs = require('fs');
const path = require('path');
const {
    readCoreRules, section, HANDLING_HEADING,
    STATE_DIR, HANDLING_MARK_PREFIX, HANDLING_MARK_BY_SESSION_START, readHookInput, sessionIdOf,
} = require('./core-rules');

const ASK_MARK_TTL_MS = 30 * 60 * 1000;

const input = readHookInput();

let rules = '';
try {
    rules = section(readCoreRules(), HANDLING_HEADING);
    if (!rules) process.stderr.write(`[hwip-ask-result] no "${HANDLING_HEADING}" section in docs/CORE_RULES.md — nothing to hand over\n`);
} catch (err) {
    process.stderr.write(`[hwip-ask-result] Could not read docs/CORE_RULES.md: ${err.message}\n`);
}
if (!rules) process.exit(0);

const inSubagent = typeof input.agent_id === 'string' && input.agent_id !== '';
const sessionId = inSubagent ? '' : sessionIdOf(input);
const mark = sessionId ? path.join(STATE_DIR, HANDLING_MARK_PREFIX + sessionId) : '';

// Held: SessionStart shipped the rules, or this hook did within the TTL.
const markHolds = () => {
    try {
        if (fs.readFileSync(mark, 'utf-8') === HANDLING_MARK_BY_SESSION_START) return true;
        return Date.now() - fs.statSync(mark).mtimeMs <= ASK_MARK_TTL_MS;
    } catch { return false; }
};
if (mark && markHolds()) process.exit(0);

// The mark goes down only once the rules are out: a failed write leaves none,
// and the next result hands them over again.
try {
    fs.writeSync(1, JSON.stringify({
        hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: rules },
    }));
} catch (err) {
    process.stderr.write(`[hwip-ask-result] could not write the hook output: ${err.message}\n`);
    process.exit(0);
}

if (mark) {
    try {
        fs.mkdirSync(STATE_DIR, { recursive: true });
        fs.writeFileSync(mark, 'ask');
    } catch { /* no mark: the next result hands the rules over again */ }
}
