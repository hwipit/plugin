#!/usr/bin/env node
'use strict';

/**
 * Validate the single-source-of-truth contract for Hwip behavioral rules.
 *
 * Source of truth: plugin/docs/CORE_RULES.md
 * Dependent docs (must REFERENCE the source, not re-mirror it):
 *   - plugin/CLAUDE.md            (auto-read system memory, condensed)
 *   - plugin/skills/hwip/SKILL.md (skill documentation, condensed)
 *
 * The dependent docs are intentionally condensed quick-references, so this
 * linter does NOT diff their prose against the source. It enforces the
 * weaker — but checkable — contract that each one still links back to
 * CORE_RULES.md and carries the load-bearing anchor terms. A broken
 * contract exits non-zero so a release/CI step can gate on it.
 *
 * Usage: node lint-rules-sync.js
 */

const fs = require('fs');
const path = require('path');
const { extractCore } = require('./extract-core.js');

const coreRulesPath = path.join(__dirname, '..', 'docs', 'CORE_RULES.md');
const claudeMdPath = path.join(__dirname, '..', 'CLAUDE.md');
const skillMdPath = path.join(__dirname, '..', 'skills', 'hwip', 'SKILL.md');

let hasErrors = false;

const log = {
    error: (msg) => { console.error(`❌ ${msg}`); hasErrors = true; },
    warn: (msg) => console.warn(`⚠️  ${msg}`),
    info: (msg) => console.log(`ℹ️  ${msg}`),
    ok: (msg) => console.log(`✓ ${msg}`),
};

/** Read a file, or exit(1) when the source of truth itself is missing. */
const readFileOrExit = (filePath, label) => {
    try {
        const content = fs.readFileSync(filePath, 'utf-8');
        log.ok(`Read ${label} (${content.length} chars)`);
        return content;
    } catch (err) {
        log.error(`Cannot read ${label}: ${err.message}`);
        process.exit(1);
    }
};

/** Read a dependent doc; a missing OR empty file is an error but not fatal. */
const readDependent = (filePath, label) => {
    try {
        const content = fs.readFileSync(filePath, 'utf-8');
        if (content.trim() === '') {
            log.error(`${label} is empty — reference contract cannot hold`);
            return '';
        }
        log.ok(`Read ${label} (${content.length} chars)`);
        return content;
    } catch (err) {
        log.error(`Cannot read ${label}: ${err.message}`);
        return '';
    }
};

/** Slice CORE_RULES between the two-way and one-way headings. */
const extractTwoWaySection = (content) => {
    const start = content.indexOf('## Two-Way Mode');
    const end = content.indexOf('## One-Way Mode');
    if (start === -1 || end === -1 || end <= start) return '';
    return content.slice(start, end);
};

/**
 * Collect distinct rule numbers from the two-way section. Rules appear
 * both as top-level list items (`9.`) and as heading references
 * (`(Rule 9)`), so both forms are gathered.
 */
const collectRuleNumbers = (section) => {
    const numbers = new Set();
    for (const m of section.matchAll(/^\s*(\d+)\.\s/gm)) numbers.add(Number(m[1]));
    for (const m of section.matchAll(/\(Rule (\d+)\)/g)) numbers.add(Number(m[1]));
    return [...numbers].sort((a, b) => a - b);
};

/** Enforce the structural markers that make CORE_RULES authoritative. */
const checkSourceMarkers = (coreRules) => {
    if (!coreRules.includes('SOURCE OF TRUTH')) {
        log.error('CORE_RULES.md missing "SOURCE OF TRUTH" marker');
    }
    if (!coreRules.includes('Last updated')) {
        log.error('CORE_RULES.md missing "Last updated" timestamp');
    }
};

/**
 * Enforce the reference contract on one dependent doc: it must link back
 * to CORE_RULES.md and carry the anchor terms that signal the rules are
 * current. Prose is intentionally NOT diffed.
 */
const checkReferenceContract = (content, label) => {
    if (!content) return;
    if (!content.includes('CORE_RULES')) {
        log.error(`${label} has no backref to CORE_RULES.md (reference contract broken)`);
    }
    if (!content.includes('hwip_ask')) {
        log.error(`${label} missing anchor term "hwip_ask"`);
    }
    if (!content.includes('REMOTE')) {
        log.warn(`${label} missing "REMOTE" — sticky-mode guidance may be stale`);
    }
};

const coreRules = readFileOrExit(coreRulesPath, 'CORE_RULES.md');
const claudeMd = readDependent(claudeMdPath, 'CLAUDE.md');
const skillMd = readDependent(skillMdPath, 'SKILL.md');

const twoWay = extractTwoWaySection(coreRules);
if (!twoWay) {
    log.error('CORE_RULES.md is missing the "## Two-Way Mode" / "## One-Way Mode" sections');
} else {
    const rules = collectRuleNumbers(twoWay);
    log.info(`CORE_RULES two-way rules detected: ${rules.length} (${rules.join(', ')})`);
}

checkSourceMarkers(coreRules);
checkReferenceContract(claudeMd, 'CLAUDE.md');
checkReferenceContract(skillMd, 'SKILL.md');

// Manifest classification contract: every ### heading in the Two-Way scope
// must be explicitly classified in core-rules.manifest.json (extractCore
// throws otherwise). This is what makes a NEW section a lint failure until
// someone decides which agents receive it.
try {
    const { sourceHash } = extractCore();
    log.ok(`Manifest classification complete (extract hash ${sourceHash.slice(0, 12)}…)`);
} catch (err) {
    log.error(`core-rules.manifest.json out of sync:\n${err.message}`);
}

console.log('\n' + '='.repeat(60));
if (hasErrors) {
    log.error('Sync validation failed — fix the contract above before publishing.');
    process.exit(1);
}
log.ok('Sync contract holds: CORE_RULES.md is authoritative and both docs reference it.');
log.info('Note: cli/src/templates.ts is regenerated via cli/scripts/sync-from-plugin.mjs; drift is enforced in cli CI.');
process.exit(0);
