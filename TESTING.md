# TESTING

This repository develops `mcrepo.sh` itself.
Never run tests that mutate files in the development repo root — the automated
suite runs every test in a disposable sandbox with an isolated `HOME`.

## Automated Test Suite

The suite lives in `tests/` and uses [bats-core](https://github.com/bats-core/bats-core).
It needs no network and no GitHub account: sub-repos are local `file://` bare
remotes, and VS Code side effects are disabled via `MCREPO_SKIP_VSCODE=1`.

```bash
tests/run.sh              # run everything
tests/run.sh 00-smoke     # run one suite
```

`tests/run.sh` uses `bats` from PATH, falling back to `npx bats@1.11.0`.

Suites:

- `00-smoke.bats` — init, add, list, status, mode switches, remove, skills
- `10-coordinated.bats` — branch → commit → merge → push flows across multiple
  repos including the meta-context, `--include-read` end to end
- `20-guards.bats` — destructive-path regression tests: sleep refuses unpushed
  work, `pull --reset` protects committed commits, carry crash, YAML
  round-trip, JSONC settings preservation, URL/branch-name validation,
  stdout/stderr contract, exit codes
- `30-inventory.bats` — command surface consistency: `MCREPO_COMMANDS`
  inventory == `usage()` == `main()` dispatch == generated completions;
  manifest schema stamping and migration
- `40-conflicts.bats` — REAL merge/rebase conflicts: the strict sync gate
  (`merge` refuses when behind parent), `sync` conflict handling + agent
  prompt, `continue`/`abort`/`resolve`, marker-less `CONFLICTED` detection
  (squash/stash-pop), partial-merge rollback + re-run resume, `#N`/batch-id
  identity fixes
- `50-origin.bats` — multi-device / origin workflow: plain `pull` integrates
  (auto-stash + rebase local commits onto remote work, then plain push),
  conflict pause + continue + re-run, `--ff-only` conservative mode,
  safe-force/ambiguous protection (never rebase onto a stale post-sync
  remote, never force away another device's commits), stuck-workspace guard

CI (`.github/workflows/ci.yml`) runs `bash -n`, shellcheck, the full suite on
ubuntu **and** macOS (stock bash 3.2 — catches `mapfile`-class and
empty-array-under-`set -u` regressions), and typechecks/bundles the VS Code
plugin.

## Writing Tests

Use the helpers from `tests/helpers.bash`:

- `setup_workspace` — disposable sandbox + isolated HOME/git config
- `make_remote <name>` — seeded local bare remote, prints its `file://` URL
- `init_workspace_with_repos <names...>` — init + add each repo
- `git_manage_workspace` — make the sandbox workspace itself git-managed so
  the meta-context participates in coordinated commands
- `mcrepo <args>` — run the sandboxed copy of the script

Every bug fix gets a regression test in `20-guards.bats`. Every new command or
flag must keep `30-inventory.bats` green (update `MCREPO_COMMANDS`, `usage()`,
and the completion generators together).

## Manual Checks (not yet automated)

- Interactive prompts: answers other than `y/yes` decline; `Enter` takes the
  shown default (see the CONVENTIONS section of `mcrepo help`).
- Shell integration idempotency: in a sandbox with isolated `HOME`, run
  `./mcrepo.sh init` twice and confirm each mcrepo block appears once in the
  rc file.
- `mcrepo update` self-update flow against a fork via `MCREPO_UPDATE_URL`.
- VS Code extension: mode badges, context menus only in mcrepo workspaces,
  reload prompt on topology changes.
- GitHub-dependent flows (`fork`, `pr`, `doctor`, org sync) with an
  authenticated `gh` — use throwaway repos, never `--force` against real work.
