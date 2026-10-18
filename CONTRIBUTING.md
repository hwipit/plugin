# Contributing to the Hwip Claude Code plugin

Bug reports, fixes and docs improvements are welcome. For a larger change, open an
issue first so we can agree on the approach before you write it.

## Set up

This repository is a Claude Code plugin made of bash hooks, skills and rule docs.
There is nothing to build. The hooks and their tests need `bash`, `jq` and `python3`;
see [tests/README.md](./tests/README.md).

```bash
git clone https://github.com/hwipit/plugin.git
cd plugin
```

## Test

```bash
bash tests/run-all.sh             # every suite under tests/
bash tests/test-hwip-stop.sh      # or one suite at a time
node scripts/lint-rules-sync.js   # validate the rules-sync contract
```

CI runs both commands on Ubuntu and macOS (macOS with the system bash 3.2), so keep
the hooks compatible with bash 3.2 and BSD tools.

## Rules

`docs/CORE_RULES.md` is the source of the behavioral rules. When you change it, read
[docs/RULES-SYNC.md](./docs/RULES-SYNC.md): the `@hwip/cli` agent templates are
generated from it.

## Commits and pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org/):
  `<type>(<scope>): <description>`, for example `fix(hooks): ...`.
- Open pull requests against `main`.
- A DCO sign-off is not required. By contributing you agree that your work is
  licensed under the Apache License 2.0, as in [LICENSE](./LICENSE).

Report security problems privately, as described in [SECURITY.md](./SECURITY.md).
