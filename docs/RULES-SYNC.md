# Rules Synchronization

## Single Source of Truth

All behavioral rules for Hwip agents are now centralized in **`CORE_RULES.md`**.

This file is the authoritative source and is read by:

1. **SessionStart Hook** (`plugin/hooks/hwip-setup.js`)
   - Reads `CORE_RULES.md` at runtime
   - Extracts the appropriate section (two-way or one-way)
   - Injects rules into Claude Code session context

2. **System Memory** (`plugin/CLAUDE.md`)
   - Should reference or mirror `CORE_RULES.md`
   - Serves as fallback documentation

3. **Skill Documentation** (`plugin/skills/hwip/SKILL.md`)
   - Should reference or mirror `CORE_RULES.md`
   - User-discoverable documentation

4. **CLI Templates** (`cli/src/hwip-core.generated.ts`, consumed by `cli/src/templates.ts`)
   - Shared across 9 agents (Cursor, Windsurf, Gemini, Codex, Copilot, Cline,
     Aider, Pi, OpenCode)
   - GENERATED: `cli/scripts/sync-from-plugin.mjs` runs this repo's
     `scripts/extract-core.js` (driven by `scripts/core-rules.manifest.json`)
     and rewrites the generated file; cli CI fails on drift
   - The extractor renumbers each assembled core to 1..N and moves the
     cross-references with it, so an audience that is missing a rule still
     reads as a whole list. The numbers here therefore do NOT line up with
     `CORE_RULES.md` — reference a rule by name when you write about both.

## Why This Matters

**Before**: Rules were duplicated in 4 locations. Manual sync required. Bugs from divergence:
- SessionStart hook outdated → old rules injected
- CLAUDE.md drifts → conflicting guidance
- SKILL.md lags → user confusion
- cli/templates.ts forgotten → agent behavior diverges

**After**: Single edit point. Hook reads at runtime. Automatic consistency.

## Maintenance

### When you change rules

1. **Edit `CORE_RULES.md`** — this is the only file you need to change
2. **If you added or renamed a `###` section** in the Two-Way scope, classify it
   in `scripts/core-rules.manifest.json` (`audiences: [...]`, or `[]` + `note`
   for a deliberate exclusion). The linter fails on unclassified headings.
3. **Verify the change**:
   ```bash
   node scripts/lint-rules-sync.js
   ```
4. **Update CLAUDE.md & SKILL.md** — these should reference the new rule, not duplicate it
   - Add a link: "See Rule 3 in [CORE_RULES.md](../docs/CORE_RULES.md)"
   - Or, if skill-specific: extract the relevant rule with attribution
5. **Regenerate the cli mirror** — in the sibling cli checkout:
   ```bash
   cd ../cli && npm run sync:plugin
   ```
   Commit the regenerated `src/hwip-core.generated.ts` there. cli CI
   cross-checks against this repo and fails on drift.
6. **Update "Last updated" timestamp** in CORE_RULES.md

### CI/Release Checklist

Before publishing a new version:

```bash
# Validate sync (reference contract + manifest classification)
npm run lint:rules-sync

# Verify CLAUDE.md references CORE_RULES.md (not hardcoded)
grep -n "See.*CORE_RULES" CLAUDE.md

# Regenerate + verify the cli mirror (sibling checkout)
cd ../cli && npm run sync:plugin -- --check

# Update version & changelog
npm version patch
```

## Migration Status

- ✅ CORE_RULES.md created (single source)
- ✅ hwip-setup.js reads from CORE_RULES.md at runtime
- ✅ CLAUDE.md — references CORE_RULES.md (condensed quick-reference, backref enforced by linter)
- ✅ SKILL.md — references CORE_RULES.md (condensed guidance, backref enforced by linter)
- ✅ cli/src/hwip-core.generated.ts — regenerated via `cli/scripts/sync-from-plugin.mjs`; drift enforced in cli CI (cross-repo checkout + `--check`)
- ✅ lint-rules-sync.js validates the reference contract AND manifest classification (exit 1 on breakage; `npm run lint:rules-sync`)

## Example: Adding a New Rule

1. Edit `CORE_RULES.md`:
   ```markdown
   ## Two-Way Mode
   
   ### [New Section]
   
   12. New rule text here...
   ```

2. The next Claude Code session will automatically inject the updated rule.

3. Update CLAUDE.md to reference it:
   ```markdown
   See Rule 12 in [CORE_RULES.md](../docs/CORE_RULES.md)
   ```

4. Update SKILL.md similarly.

5. Classify the new section in `scripts/core-rules.manifest.json`, then
   regenerate the cli mirror:
   ```bash
   cd ../cli && npm run sync:plugin
   ```

## Files Modified

- **Created**: `plugin/docs/CORE_RULES.md` (authoritative rules)
- **Created**: `plugin/scripts/lint-rules-sync.js` (validation script)
- **Created**: `plugin/scripts/core-rules.manifest.json` (section → audience map)
- **Created**: `plugin/scripts/extract-core.js` (manifest-driven extractor)
- **Created**: `plugin/docs/RULES-SYNC.md` (this file)
- **Modified**: `plugin/hooks/hwip-setup.js` (now reads CORE_RULES.md)
