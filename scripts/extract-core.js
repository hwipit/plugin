#!/usr/bin/env node
'use strict';

/**
 * Manifest-driven extraction of CORE_RULES.md into the per-audience rule
 * cores consumed by @hwip/cli (cli/src/hwip-core.generated.ts).
 *
 * Reads scripts/core-rules.manifest.json, slices docs/CORE_RULES.md between
 * the scope headings, splits the scope at `###` boundaries, and assembles
 * one rule document per audience (hook-driven / rule-only) in manifest order,
 * then renumbers each so its rule list reads 1..N (see renumberRules).
 *
 * The anti-drift contract: every `###` heading inside the scope must be
 * classified in the manifest (and vice versa). A new section added to
 * CORE_RULES.md is a hard error here until someone explicitly assigns its
 * audiences — deliberate exclusions are `audiences: []` plus a note.
 *
 * Usage:
 *   node scripts/extract-core.js           # validate only (used by lint)
 *   node scripts/extract-core.js --json    # emit {hookDriven, ruleOnly, sourceHash}
 *
 * Exported for lint-rules-sync.js: extractCore() throws on contract breach.
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PLUGIN_ROOT = path.join(__dirname, '..');
const MANIFEST_PATH = path.join(__dirname, 'core-rules.manifest.json');

const AUDIENCES = ['hook-driven', 'rule-only'];

/** Slice the source between the scope start/end headings (exclusive of both). */
const sliceScope = (source, scope) => {
    const start = source.indexOf(scope.start);
    const end = source.indexOf(scope.end);
    if (start === -1 || end === -1 || end <= start) {
        throw new Error(`scope headings not found or out of order: "${scope.start}" .. "${scope.end}"`);
    }
    return source.slice(start + scope.start.length, end);
};

/** Split scoped text at `###` boundaries → [{heading, body}] in document order. */
const splitSections = (scoped) => {
    const sections = [];
    const re = /^### .*$/gm;
    const matches = [...scoped.matchAll(re)];
    for (let i = 0; i < matches.length; i++) {
        const from = matches[i].index;
        const to = i + 1 < matches.length ? matches[i + 1].index : scoped.length;
        sections.push({
            heading: matches[i][0].trim(),
            // Trim a trailing horizontal rule — the last section's slice runs
            // to the scope end, which sits just above a `---` separator.
            text: scoped.slice(from, to).trim().replace(/\n+---\s*$/, ''),
        });
    }
    return sections;
};

/** Enforce the two-way classification contract; return sections keyed by heading. */
const classify = (sections, manifest) => {
    const manifestHeadings = manifest.sections.map((s) => s.heading);
    const sourceHeadings = sections.map((s) => s.heading);

    const unclassified = sourceHeadings.filter((h) => !manifestHeadings.includes(h));
    const stale = manifestHeadings.filter((h) => !sourceHeadings.includes(h));
    const errors = [
        ...unclassified.map((h) => `unclassified heading in CORE_RULES.md scope: "${h}" — add it to core-rules.manifest.json (audiences: [...] or [] + note)`),
        ...stale.map((h) => `manifest heading not found in CORE_RULES.md scope: "${h}" — remove or fix it in core-rules.manifest.json`),
    ];
    for (const s of manifest.sections) {
        const bad = (s.audiences || []).filter((a) => !AUDIENCES.includes(a));
        if (bad.length) errors.push(`unknown audience(s) ${bad.join(', ')} on "${s.heading}"`);
    }
    if (errors.length) {
        throw new Error(errors.join('\n'));
    }
    return new Map(sections.map((s) => [s.heading, s.text]));
};

/** Assemble one audience's core: included sections joined in manifest order. */
const assemble = (byHeading, manifest, audience) =>
    manifest.sections
        .filter((s) => (s.audiences || []).includes(audience))
        .map((s) => byHeading.get(s.heading))
        .join('\n\n');

/**
 * Ordered-list markers, column-0 anchored: an indented sub-list inside a rule
 * is prose, not a rule, and must not be renumbered.
 */
const RULE_MARKER_RE = /^(\d+)\. /gm;

/**
 * `Rule 9`, `Rules 3, 4, 10 and 11` — a reference and every number it carries.
 * Case-insensitive on the word: a mid-sentence `rule 12` that this pass skipped
 * would keep its old number silently, which is the one outcome the hard-fail
 * below exists to prevent.
 */
const RULE_REF_RE = /\b[Rr]ules?\s+\d+(?:(?:,\s*|\s+and\s+|\s+or\s+|\s*[-–]\s*)\d+)*/g;

/**
 * Renumber an assembled core so its list reads 1..N, moving cross-references
 * with it.
 *
 * The manifest drops rules 1-2 and 12, so the raw slice opens at 3 and jumps
 * 11 → 13 — a numbered list that reads as truncated context, which is the
 * opposite of the intended signal. Numbering is a render concern: the source
 * keeps its own numbers (the Claude Code hooks inject sections verbatim, and
 * the doc has to stay readable on its own) and each audience gets a whole list.
 *
 * A reference to a rule this audience never received has no number to point
 * at, so it throws rather than renumbering around it — a silently wrong
 * cross-reference is worse than the gap it papers over.
 */
const renumberRules = (text) => {
    const mapping = new Map();
    for (const m of text.matchAll(RULE_MARKER_RE)) mapping.set(m[1], String(mapping.size + 1));

    const unmapped = new Set();
    const renumbered = text
        .replace(RULE_MARKER_RE, (_, n) => `${mapping.get(n)}. `)
        .replace(RULE_REF_RE, (ref) =>
            ref.replace(/\d+/g, (n) => {
                const to = mapping.get(n);
                if (to === undefined) unmapped.add(`Rule ${n}`);
                return to === undefined ? n : to;
            }),
        );
    if (unmapped.size) {
        throw new Error(
            `cross-reference to a rule this core does not carry: ${[...unmapped].join(', ')}` +
                " — reword it in CORE_RULES.md, or give that rule's section this audience",
        );
    }
    return renumbered;
};

/**
 * Extract both audience cores. Throws with a multi-line message when the
 * manifest and CORE_RULES.md disagree.
 */
const extractCore = () => {
    const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf-8'));
    const sourcePath = path.join(PLUGIN_ROOT, manifest.source);
    const source = fs.readFileSync(sourcePath, 'utf-8');

    const scoped = sliceScope(source, manifest.scope);
    const sections = splitSections(scoped);
    const byHeading = classify(sections, manifest);

    const hookDriven = renumberRules(assemble(byHeading, manifest, 'hook-driven'));
    const ruleOnly = renumberRules(assemble(byHeading, manifest, 'rule-only'));
    const sourceHash = crypto
        .createHash('sha256')
        .update(JSON.stringify(manifest))
        .update(hookDriven)
        .update(ruleOnly)
        .digest('hex');

    return { hookDriven, ruleOnly, sourceHash };
};

module.exports = { extractCore, renumberRules };

if (require.main === module) {
    let result;
    try {
        result = extractCore();
    } catch (err) {
        console.error(`❌ extract-core: ${err.message}`);
        process.exit(1);
    }
    if (process.argv.includes('--json')) {
        process.stdout.write(JSON.stringify(result));
    } else {
        console.log(`✓ extract-core: manifest and CORE_RULES.md agree (hash ${result.sourceHash.slice(0, 12)}…)`);
    }
}
