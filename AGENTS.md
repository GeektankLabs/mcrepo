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

- If CLI behavior changes, update `README.md` in the same change.
- Keep install and quickstart examples runnable.
- Keep platform notes accurate (macOS-first, Linux target).

## Testing Rules

- Do not run destructive tests in the development repo root.
- Use isolated sandbox directories and isolated `HOME` values.
- Prefer `./mcrepo.sh init --no-shell-install` for automated/sandbox testing.
- Follow `TESTING.md` for repeatable checks.

## Commit Hygiene

- Make focused, minimal changes.
- Avoid unrelated refactors in the same change.
- Keep user-facing messages clear and action-oriented.

## Versioning Rule

- When an AI agent edits `mcrepo.sh`, it must also bump `MCREPO_VERSION` in the same change.
- Use a patch-only bump: increment only the right-most version segment (`x.y.z` -> `x.y.(z+1)`).
- The patch segment is unbounded (`...9` can become `...10`, `...11`, etc.).
