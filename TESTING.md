# TESTING

This repository develops `mcrepo.sh` itself.
Do not run tests that mutate files in the development repo root.

## Principles

- Always test in a disposable sandbox directory.
- Always use an isolated `HOME` to avoid touching your real shell rc files.
- Prefer `./mcrepo.sh init --no-shell-install` for automated checks.
- `./mcrepo.sh init` should produce clean repo folder names.

## Quick Sandbox Smoke Test

Run from the development repo root:

```bash
tmp="$(mktemp -d)"
cp "./mcrepo.sh" "$tmp/mcrepo.sh"
chmod +x "$tmp/mcrepo.sh"
mkdir -p "$tmp/home"

HOME="$tmp/home" bash -lc 'cd "'"$tmp"'" && ./mcrepo.sh init --no-shell-install'
HOME="$tmp/home" bash -lc 'cd "'"$tmp"'" && ./mcrepo.sh add https://github.com/octocat/Hello-World.git hello-world'
HOME="$tmp/home" bash -lc 'cd "'"$tmp"'" && ./mcrepo.sh list'
HOME="$tmp/home" bash -lc 'cd "'"$tmp"'" && ./mcrepo.sh status'
HOME="$tmp/home" bash -lc 'cd "'"$tmp"'" && ./mcrepo.sh write hello-world'
HOME="$tmp/home" bash -lc 'cd "'"$tmp"'" && ./mcrepo.sh read hello-world'
HOME="$tmp/home" bash -lc 'cd "'"$tmp"'" && ./mcrepo.sh sleep hello-world --force'
HOME="$tmp/home" bash -lc 'cd "'"$tmp"'" && ./mcrepo.sh sleep --wakeall'
HOME="$tmp/home" bash -lc 'cd "'"$tmp"'" && ./mcrepo.sh skill list'
HOME="$tmp/home" bash -lc 'cd "'"$tmp"'" && ./mcrepo.sh skill validate'
```

Optional cleanup:

```bash
rm -rf "$tmp"
```

## What to Verify

- `mcrepo.yaml` is created and updated correctly.
- Support directories are generated.
- Separator directory is not created.
- Mode switches keep clean repo folder names (no mode-prefix renames).
- `sleep --force` clears local repo contents and leaves `.gitignore` plus `.mcrepo-sleep` placeholder files.
- `sleep --wakeall` restores sleeping repos to `read` mode.
- `🧠 skills/` is generated with a default skill pack and template.
- `.opencode/skills/` is generated as mirror for OpenCode discovery.
- `mcrepo skill list` shows skill states.
- `mcrepo skill validate` passes on a fresh workspace.
- `mcrepo skill install <github-url>` installs a skill into workspace scope.
- `mcrepo skill <repo-name> install <github-url|clawhub-url>` installs into sub-repo `.opencode/skills/` when repo is in write mode.
- `init --no-shell-install` does not write shell integration blocks.
- `init` keeps plain repo folder names without mode prefixes.
- Re-running `init` removes legacy separator directories when they are empty.

## Manual Check for Shell Integration Idempotency

In a sandbox with isolated `HOME`:

```bash
tmp="$(mktemp -d)"
cp "./mcrepo.sh" "$tmp/mcrepo.sh"
chmod +x "$tmp/mcrepo.sh"
mkdir -p "$tmp/home"

HOME="$tmp/home" bash -lc 'cd "'"$tmp"'" && ./mcrepo.sh init'
HOME="$tmp/home" bash -lc 'cd "'"$tmp"'" && ./mcrepo.sh init'
```

Then inspect the sandbox rc file (`$tmp/home/.bashrc` or `$tmp/home/.zshrc`) and confirm each mcrepo block appears once.
