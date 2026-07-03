# AGENTS.md (Development Repo)

This file defines how AI agents should work in this repository, which develops `mcrepo.sh` itself.

## Mission

- Treat `mcrepo` as a self-contained product.
- Keep the tool lightweight and shell-first.
- Optimize for AI-agent-first multi-repo workflows.

## Scope

- This repository is for developing `mcrepo.sh`.
- It is not the generated runtime workspace that `mcrepo.sh init` creates for users.
- Changes here should improve behavior for generated workspaces.

## Development Rules

- Keep `mcrepo.yaml` compatibility stable unless intentionally changed and documented.
- Prefer safe defaults over convenience when data loss is possible.
- Preserve per-repo autonomy (commits/releases remain inside each managed repository).
- Branch coordination is in scope; central release orchestration is not required.

## Documentation Rules

- If CLI behavior changes, update `README.md`, `usage()` in `mcrepo.sh`, and the completion generators in the same change. When adding/removing/renaming a command, also update `MCREPO_COMMANDS` — `tests/30-inventory.bats` enforces that inventory, usage, dispatch, and completions agree.
- Breaking changes must be added to the "Upgrading from 0.5.x" section of `README.md`.
- Keep install and quickstart examples runnable.
- Keep platform notes accurate (macOS + Linux, stock bash 3.2 supported).

## Testing Rules

- Do not run destructive tests in the development repo root.
- Use isolated sandbox directories and isolated `HOME` values.
- Prefer `./mcrepo.sh init --no-shell-install` for automated/sandbox testing.
- Follow `TESTING.md` for repeatable checks.

## Commit Hygiene

- Make focused, minimal changes.
- Avoid unrelated refactors in the same change.
- Keep user-facing messages clear and action-oriented.
- When testing `mcrepo commit` locally, prefer sandbox directories (per "Testing Rules"); `commit --revert` and `commit --reset` are destructive.

## Versioning Rule

- When an AI agent edits `mcrepo.sh`, it must also bump `MCREPO_VERSION` in the same change.
- When an AI agent edits any file under `vsc-plugin/src/` or `vsc-plugin/package.json`, it must also bump the `version` field in `vsc-plugin/package.json` in the same change.
- Use a patch-only bump: increment only the right-most version segment (`x.y.z` -> `x.y.(z+1)`).
- The patch segment is unbounded (`...9` can become `...10`, `...11`, etc.).
- Minor/major bumps are deliberate release decisions made by the maintainer (release milestones), not automatic agent behavior. A minor/major release must document its breaking changes in the README upgrade section.
