# mcrepo.sh

An AI-agent-first Meta-Context-Repository approach for MacOS and Linux.
It lets you work across many independent Git repositories in one local directory context, without migrating them into a monorepo. All managed by just one shell script: `mcrepo.sh`

![mcrepo workspace banner](assets/mcrepo-banner.svg)

## Install & Setup

- Create an empty repository
- Open it in VSCode (optional)
- Open Terminal

Excute one-liner in empty repository:

```bash
curl -fsSL https://raw.githubusercontent.com/GeektankLabs/mcrepo/main/mcrepo.sh -o ./mcrepo.sh && chmod +x ./mcrepo.sh && ./mcrepo.sh init
```

After `init`, close terminal and open a new one:

```bash
mcrepo help
```

Add repositories to your meta context:

```bash
mcrepo add <git-url>
```

If you added all needed repositories to your Meta-Context-Repository then run the suggested prompt with your local AI agent tool of choice (OpenCode, Codex CLI, Claude Code, etc) - they have now all those repositories as context and can make coordinated feature changes, documentation and integrated dev & tests setups for you.

## Modes and Visibility

Every added repository starts in `read` mode.

- `👀 read`: context available, no edits intended
- `✍️ write`: active repository where changes should be done
- `💤 sleep`: currently not relevant; reduce active scope

Switch modes with:

```bash
mcrepo write <repo-name>
mcrepo read <repo-name>
mcrepo sleep <repo-name>
mcrepo status
```

By default, folder names use these emoji prefixes, which makes mode status easy to spot in VS Code file explorer.

## Branch Coordination

Before implementing a cross-repo feature, set one coordinated branch name across write repositories:

```bash
mcrepo branch <feature-branch-name>
```

This keeps feature work aligned and makes later per-repo commits and pull requests easier to coordinate.

## VS Code Workflow

- Keep the meta-context root open in one VS Code window to see all repositories and mode folders (`✍️`, `👀`, `💤`).
- If a write repository has changes, open it in a dedicated VS Code window:

```bash
mcrepo open <repo-name>
```

- Commit and push inside that repository, preserving per-repo autonomy.

## Directory Structure After Init

`init` generates coordination directories in the meta-context root:

- `🛠 scripts/`: helper scripts for this meta workspace
- `🧩 contracts/`: cross-repo interfaces and contracts
- `🧾 docs/`: architecture, integration notes, and generated overviews
- `🧪 tests/`: integration test setup and shared test assets
- `mcrepo.yaml`: source of truth for repos, modes, descriptions, branch and path style

## AI-Agent-First Starter Tasks

After adding repositories, useful first tasks are:

1. Ask your agent to scan all `read` repos and write an interface map into `🧾 docs/`.
2. Ask your agent to scaffold an integration test setup (for example Docker Compose) in `🧪 tests/`.
3. Ask your agent which repos should be switched to `write` for your next feature.

## Why This Instead of a Monorepo?

- No full migration of codebases into one repository.
- No forced unified build and release system.
- Still supports coordinated cross-repo feature work.
- Better fit when repos are already split by ownership and domain.

This means lightweight context orchestration, not a central release manager.

## Private Meta-Repo Pattern

You can keep component repositories public/open-source while keeping the `mcrepo` workspace repository private for internal coordination.

## Additional Options

- Skip shell config installation during init (recommended for CI or disposable sandboxes):

```bash
./mcrepo.sh init --no-shell-install
```

- Disable emoji-prefixed mode folders and use clean folder names (no mode prefix in directory names):

```bash
./mcrepo.sh init --no-emojis
```

## Versioning and Self-Update

- `mcrepo.sh` includes a built-in script version and prints it on each run.
- By default, `mcrepo` checks the canonical upstream script (`GeektankLabs/mcrepo`, `main`, `mcrepo.sh`) and notifies you when a newer version exists.
- Run `mcrepo update` to self-update the script in place.
- Override update source URL (for forks/mirrors) with `MCREPO_UPDATE_URL`.
- Disable automatic update checks with `MCREPO_DISABLE_UPDATE_CHECK=1`.

## Patch Submission Without Repository Checkout

- Run `mcrepo export-patch [topic]` (or `mcrepo create-patch [topic]`).
- The command prints everything to stdout:
  - submission steps and issue URL
  - issue title
  - full issue body with embedded `mcrepo.sh` patch against canonical upstream
- Open a new issue, use title prefix `[PATCH SUBMISSION]`, paste the printed issue body, and submit.
- Ask maintainers to add label `patch submission` and assign the issue to Copilot coding agent to turn it into a PR.

## Platforms

- Current focus: macOS
- Target support: Linux

## Origins

The approach comes from practical maintainer experience in multi-repository open-source work, including the RaspiBlitz ecosystem.
