# mcrepo.sh

An AI-agent-first **Multi-Context Repository** (MC-Repo) tool for macOS and Linux.
It lets you work across many independent Git repositories in one local directory context, without migrating them into a monorepo. All managed by just one shell script: `mcrepo.sh` with practical workspace governance for multi-repo agent workflows.

The workspace root that holds `mcrepo.yaml` and the shared `+-` folders is called the **meta-context repo** throughout this document and in command output (see the [Glossary](#glossary)).

![mcrepo workspace banner](assets/mcrepo-banner.svg)

## Install & Setup

### Prerequisites

- bash 3.2+ (macOS stock bash works), git (2.38+ required for `mcrepo merge`'s conflict dry-run)
- optional: [GitHub CLI `gh`](https://cli.github.com/) for fork/PR/access-check features, `python3` for VS Code settings sync, `jq` for organization sync without `gh`

### Setup

- Create an empty repository
- Open it in VSCode (optional)
- Open Terminal

Excute one-liner in empty repository:

```bash
curl -fsSL https://raw.githubusercontent.com/GeektankLabs/mcrepo/main/mcrepo.sh -o ./mcrepo.sh && chmod +x ./mcrepo.sh && ./mcrepo.sh init
```

`init` automatically downloads and installs the mcrepo VS Code extension when the `code` CLI is available. To install or reinstall the extension manually at any time:

```bash
mcrepo install-extension
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

### Publishing the workspace itself

The base mcrepo workspace can be either a plain directory or a git repository. To make it git-managed and back it up to an empty external remote (e.g. a freshly-created empty GitHub repo) in one step:

```bash
mcrepo publish-base <git-url>
```

`publish-base` is safe to run whether or not the workspace already has a `.git/`:

- if no `.git/` yet → `git init` first, then commit and push
- if `.git/` exists with no `origin` → attach origin and push
- if `.git/` exists with `origin` already pointing to `<git-url>` → just push (idempotent)

Before the first commit, `publish-base` reconciles `.gitignore` against `mcrepo.yaml` so that external sub-repos stay excluded and local incubator sub-repos stay tracked. This guards against accidentally bundling an external sub-repo's working tree into the workspace's initial commit.

## Modes and Visibility

Repositories added with `mcrepo add <git-url>` start in `read` mode; fork/upstream workflows (`add --fork`, `fork`, interactive upstream choices) default to `write` since their purpose is contributing changes.

- `👀 read`: context available, no edits intended
- `✏️ write`: active repository where changes should be done
- `💤 sleep`: currently not relevant; reduce active scope

Switch modes with:

```bash
mcrepo write <repo-name>
mcrepo read <repo-name>
mcrepo sleep <repo-name>
mcrepo status
```

Repository folder names are always clean (no mode or emoji prefix in directory names). Mode visibility is tracked in `mcrepo.yaml` and can be decorated in the editor.

When a repo is set to `sleep`, mcrepo clears the local checkout **including `.git`** and leaves two placeholders in that folder: `.gitignore` and `.mcrepo-sleep`. Switching back to `read` or `write` checks out the repository again.

Because sleeping deletes the clone, mcrepo first scans for local work that would be lost — uncommitted changes, untracked files, unpushed commits on any branch, stashes — and refuses (or prompts) when it finds any. `sleep <repo> --force` discards such work explicitly.

## Incubator Sub-Repos

To quickly try out a new project idea inside an mcrepo workspace - without first creating an external git repo - use `mcrepo new`:

```bash
mcrepo new my-new-idea
```

This creates `./my-new-idea/` and records it in `mcrepo.yaml` with `local: true` (no `url:`). The directory is **tracked by the base mcrepo** (not gitignored) so its files become part of the base mcrepo's git history as you work on them. There is no separate `.git/` inside the incubator yet.

While a sub-repo is in local incubator state:

- `mcrepo list` shows it with a 🌱 indicator.
- Modes (`write` / `read` / `sleep`) still apply as **pure agent-intent signals**. Unlike external repos, `sleep` on a local repo is non-destructive: it just flips the mode tag; the files stay on disk and in base history.
- Per-repo git operations (`mcrepo pull`, `push`, `branch`, `merge`, per-repo `commit`) silently skip local repos since they have no `.git/` yet.
- You commit changes to local repo files via the base mcrepo's normal `git add` / `git commit` workflow (or just leave them as files if base isn't git-managed yet - see `publish-base` above).

When the idea proves itself, graduate the repo to a fresh external remote:

```bash
# 1. Create an empty repo on GitHub (or any git service), copy its URL
# 2. Graduate the incubator:
mcrepo publish my-new-idea git@github.com:me/my-new-idea.git
```

`publish` will:

1. Validate the remote URL is reachable and empty (refuses non-empty remotes unless `--force`).
2. If the base mcrepo is a git repo: `git rm -r --cached` the dir to untrack, add `/my-new-idea/` to base `.gitignore`, and create a scoped commit recording the untracking. (Old base history still contains the files - non-destructive.)
3. `git init` inside `./my-new-idea/`, stage all files, commit them as the initial commit (default message `Initial commit`, override with `-m`).
4. Add `origin` remote pointing to the URL and push.
5. Update `mcrepo.yaml`: remove `local: true`, add the external `url:`.

From that point on, mcrepo treats the repo like any other external sub-repo (pull/push/branch/merge apply normally).

## Branch Coordination

Before implementing a cross-repo feature, set one coordinated branch name across write repositories:

```bash
mcrepo branch <feature-branch-name>
```

Behavior details:

- When `<name>` already exists locally or on origin, mcrepo treats this as a **branch jump** — no parent is recorded. When `<name>` is new, it's a **fork** — the current branch is recorded as parent.
- If forking, mcrepo shows a confirmation prompt listing which repos will fork vs jump.
- If any target repo has uncommitted changes, mcrepo offers interactive options:
  - **Abort** — stop and handle manually
  - **Commit** — auto-commit to current branch before switching
  - **Carry** — carry changes into the target branch (stash + pop, with dry-run safety check)
  - **Discard** — discard all uncommitted changes
- For scripts and agents, preselect the answer with `--dirty abort|commit|carry|discard` (non-interactive runs abort by default).
- If a carry run is interrupted (Ctrl-C), re-running `mcrepo branch <name>` finishes the switch and restores the carried stashes automatically; `mcrepo status` shows a `stash=N` indicator for repos with stashes.
- If `<name>` exists on `origin` but not locally, mcrepo creates a local tracking branch from `origin/<name>`.
- After updating target repos, mcrepo switches the meta-context repo to the same branch as the final step.
- Each repo's previous branch is automatically recorded as its parent branch in `mcrepo.yaml`, enabling `mcrepo merge` later (only on fork, not on jump).

This keeps feature work aligned and makes later per-repo commits and pull requests easier to coordinate.

To turn off coordinated branching (last-resort fallback):

```bash
mcrepo branch --off
```

After `--off`, repos remain on their current branches without coordination. For a cleaner workflow, prefer `mcrepo merge` (integrate changes) or `mcrepo branch --delete` (discard branch).

### Discarding a Branch

To discard the current global branch and switch all repos back to their parent branches:

```bash
mcrepo branch --delete
```

This is the counterpart to `mcrepo merge`. While `merge` saves work into the parent, `--delete` discards the feature branch entirely:
- Aborts if any repo has uncommitted changes
- Switches each repo back to its immediate parent branch
- Deletes the feature branch locally
- Pops the parent stack one level (nested branches supported)

### Merging Back

After feature work is complete, squash the coordinated branch back into each repo's parent branch:

```bash
mcrepo merge                  # squash; subject defaults to the source branch name
mcrepo merge -m "feat: ..."   # squash with explicit subject
mcrepo merge --include-read   # also merge read-mode repos that joined via 'branch --include-read'
mcrepo merge --no-squash      # legacy: --no-ff merge commit per repo
```

`merge` needs git 2.38+ (it dry-runs conflicts with `git merge-tree --write-tree`; `mcrepo doctor` checks this).

If the dry-run detects conflicts, sync with the parent branch first:

```bash
mcrepo merge --rebase
```

Behavior details:

- `mcrepo merge` requires a global branch to be set.
- **Default strategy is squash.** Each repo gets one new commit on its parent whose subject is either `-m "..."` or the source branch name. WIP commits on the feature branch are collapsed away. Use `--no-squash` for the previous `git merge --no-ff` behavior.
- Parent branches are recorded automatically by `mcrepo branch` — each repo can have a different parent.
- The meta-context repo (`.`) participates in both branching and merging with its own parent tracking (`meta-parent:` in `mcrepo.yaml`).
- `merge` performs a dry-run across ALL repos first. If any would conflict, no merges happen.
- `merge --rebase` rebases the current branch onto its parent (prefers `origin/<parent>` so it picks up newly merged work from other PRs; falls back to local `<parent>` when no origin is configured). Auto-stashes uncommitted work (including untracked files). This rewrites local history, so a branch that was already pushed will diverge from its remote. mcrepo flags those branches at the end of the rebase and tells you to run `mcrepo push` — which auto force-with-leases them (see [Pushing](#pushing)); you do **not** need to force-push by hand.
- On a rebase conflict, `merge --rebase` prints per-repo context for the three colliding sides (local feature branch vs parent `main` vs the stale `origin/<branch>`) and a paste-ready prompt you can hand to a local coding agent to resolve the conflict, then finish with `mcrepo continue` and `mcrepo push`.
- Merges are local only (no push). Review and push per-repo when ready.
- Nested branches are supported: `main → feature → sub-feature`. Each `merge` pops one level.
- After a squash merge, the source branch's tip is no longer reachable from the parent, so the post-merge cleanup uses **force-delete** (`git branch -D`) with an explicit confirmation defaulting to **No**. The `--no-squash` path keeps the previous safe-delete (`git branch -d`) prompt.
- The merge auto-commits the updated `mcrepo.yaml` in the meta-context (subject: `mcrepo: post-merge state — '<source>' merged into '<target>'`) so the popped parent stack and updated global branch land in git history immediately. Run `mcrepo push` afterward to publish the merge along with this state commit. Only `mcrepo.yaml` is staged — unrelated dirty files in the meta-context are left alone.
- When no parent is recorded, mcrepo falls back to detecting the default branch (via `origin/HEAD`, remote query, or heuristic).

### Resuming or Aborting Mid-Operation Repos

If `mcrepo merge`, `mcrepo merge --rebase`, or any per-repo `git` operation
left some repos mid-merge / mid-rebase / mid-cherry-pick / mid-revert, you can
drive the recovery across all affected repos at once:

```bash
mcrepo continue   # runs git <op> --continue in every mid-op repo
mcrepo abort      # runs git <op> --abort in every mid-op repo
```

Resolve the conflicts inside each repo first (the per-repo paths are visible
via `mcrepo status` under `inprogress=…`), then run `mcrepo continue`. Sleep
mode repos are skipped. The meta-context repo participates as well.

## Coordinated Commits

Commit related changes across all dirty write repos (and the meta-context) as one logical unit:

```bash
mcrepo commit -m "message"          # coordinated commit across dirty write repos + meta-context
mcrepo commit --include-read -m ".."# also include read-mode repos
mcrepo commit --revert              # peel the newest coordinated commit off HEAD (reset --hard HEAD~1)
mcrepo commit --reset               # discard uncommitted changes across all target repos
```

Behavior details:

- Each coordinated commit gets a subject `mcrepo commit #N @<batch-id>: <message>` so the group can be recognized later.
- `--revert` only peels repos whose HEAD carries the same `#N` **on the same branch and with the same batch id** — repos on other branches or with mismatched batch ids are skipped (override with `--force`). It refuses without `--force` when the commit is already pushed.
- `--revert`/`--reset` are destructive; non-interactive runs require `--force`.

## Pulling

```bash
mcrepo pull            # fetch + ff-pull all active repos; dirty sub-repos are skipped
mcrepo pull --rebase   # auto-stash, pull, pop stash for ALL repos (handles dirty repos safely)
mcrepo pull --reset    # discard local changes and reset to origin state (destructive!)
```

Behavior details:

- The meta-context auto-stashes on dirty so unrelated edits never block its pull.
- `--reset` confirms before discarding uncommitted changes, and **separately per repo** before discarding committed-but-unpushed commits (it lists them first). `--yes` skips both confirmations for automation; without it, non-interactive runs keep such repos untouched.
- Diverged branches that are provably your own local rebase are reported as "rebased locally" — publish them with `mcrepo push`. Genuinely diverged branches print a paste-ready recovery prompt for a coding agent.

## Pushing

```bash
mcrepo push                 # fetch, refuse if behind, then push ahead repos
mcrepo push -m "message"    # also commit dirty write-mode repos before pushing
mcrepo push --include-read  # also push read-mode repos (coordinated --include-read work)
mcrepo push --no-fetch      # skip the safety fetch (faster, less safe)
mcrepo push --no-force      # disable auto force-with-lease for rebased branches
```

Behavior details:

- Before pushing, mcrepo fetches `origin` for every push target (write-mode
  sub-repos plus meta-context). It then computes both **ahead** and **behind**
  per repo.
- **Rebased branches are auto-published.** After `mcrepo merge --rebase`, a
  coordinated branch diverges from its already-pushed `origin/<branch>` (ahead
  *and* behind) purely because the rebase rewrote its commit hashes. mcrepo
  detects this case — local `HEAD` already contains the parent `main` *and* the
  remote branch is stale (predates that merge) — and publishes it with
  `git push --force-with-lease` (shown as `[REBASED -> force-push]` in the plan).
  Because force-with-lease runs only after a fresh fetch, a remote that moved
  since the fetch aborts the push instead of clobbering another machine's work.
  Pass `--no-force` (or `--no-fetch`) to opt out.
- If a target is behind in a way that is **not** a provable rebase (the remote
  already contains work mcrepo can't attribute to your rebase), `push` aborts
  before any commit or push happens, suggests `mcrepo pull` / `mcrepo pull
  --rebase`, and prints a paste-ready prompt you can hand to a local coding
  agent to resolve the divergence. This avoids partial-success runs where the
  first repos succeed and the rest get rejected mid-run.
- Failures from `git push` (auth, branch protection, hooks, non-fast-forward)
  are now printed verbatim above the summary so the cause is visible.
- Without `-m` and in non-interactive context, dirty repos are skipped (not
  silently committed). With `-m "msg"` (or interactive prompt) dirty repos
  are auto-committed via `git add -A`.
- The meta-context repo is pushed last so that sub-repo references in the
  meta-context can capture the freshly pushed sub-repo states.

## Fork & PR Workflow

For repos where you lack push access, mcrepo manages the fork triangle (origin = your fork, upstream = the original repo):

```bash
mcrepo add <git-url>              # interactive when GitHub + gh: offers origin / fork / upstream / read-only
mcrepo fork <repo-or-url> [name]  # fork via gh: origin=your fork, upstream=original
mcrepo fork --all [--yes]         # fork+rewire every repo where you lack push access (plan + confirm)
mcrepo upstream                   # show origin/upstream per repo
mcrepo upstream <repo> <url>      # set/replace the PR target for the fork workflow
mcrepo upstream <repo> --off      # remove the upstream relationship
mcrepo doctor                     # git/gh/auth status + per-repo origin/upstream/access report
```

`mcrepo write <repo>` also checks push access (with `gh`) and offers to fork on the spot when you have none.

After coordinated work on a global branch, open pull requests for every repo with commits against its base:

```bash
mcrepo pr                          # coordinated PRs per repo, cross-linked with each other
mcrepo pr -m "title" [--draft]     # explicit title / draft PRs
mcrepo pr --target origin|upstream # choose the PR target; defaults to upstream when set (fork workflow)
mcrepo pr --no-push                # do not auto-push the branch before opening PRs
```

Each PR body links the sibling PRs so reviewers see the whole coordinated change set.

## Removing a Repository

```bash
mcrepo remove <name-or-url>              # drop the manifest entry and delete the local folder
mcrepo remove <name-or-url> --keep-files # keep the folder, only drop the entry
```

Before deleting, mcrepo scans for local work (uncommitted/untracked/unpushed on any branch/stashes) and prompts; `--force` skips all prompts.

## Organization Sync

`mcrepo init <organization>` imports all non-archived repos of a GitHub organization into the manifest (via `gh`, falling back to the public API with `curl`+`jq`).

## Status

```bash
mcrepo status
```

Per repo, mcrepo prints:

- `mode` (read/write/sleep), `local` (checked out yes/no), `branch`
- `state` — `clean` / `dirty`
- `upstream=<…>` — `in-sync`, `ahead=N behind=M`, or `no-upstream`
  (computed from local refs only — run `mcrepo pull` or `mcrepo push` to
  refresh first if you need the latest remote state)
- `inprogress=<…>` — `MERGING` / `REBASING` / `CHERRY-PICKING` / `REVERTING`
  / `BISECTING` when the repo is mid-operation
- `OFF-GLOBAL` — when the global branch is set but this repo sits on a
  different branch
- `parent=<stack>` — recorded parent branch stack (see Branch Coordination)

## VS Code Workflow

- Keep the meta-context root open in one VS Code window to see all repositories and shared coordination folders.
- `🗂` is the simplified mcrepo context logo used for MC-Repo actions in UI labels.
- During `./mcrepo.sh init`, mcrepo ensures `.vscode/settings.json` exists with SCM multi-repository defaults (`alwaysShowRepositories`, `selectionMode=multiple`, `autoRepositoryDetection=subFolders`, `repositoryScanMaxDepth=2`). Existing settings files are kept unchanged.
- mcrepo maintains `git.ignoredRepositories` in `.vscode/settings.json` for repos currently in `sleep` mode to reduce stale SCM detection; existing user entries are preserved.
- After `init`, mcrepo attempts to trigger a VS Code window reload via the `code` CLI; if that is not possible, it prints a hint to reload/restart VS Code manually.
- In the VS Code Explorer context menu (sub-repo folder right-click), the extension shows MC-Repo mode actions as `🗂 ✏️ Set Write`, `🗂 👀 Set Read`, and `🗂 💤 Set Sleep`.
- The VS Code extension watches `mcrepo.yaml` / `.vscode/settings.json` and prompts a window reload when repo topology changes (new repo or sleep<->active transitions) may require SCM refresh.
- If a write repository has changes, open it in a dedicated VS Code window:

```bash
mcrepo open <repo-name>
```

- Commit and push inside that repository, preserving per-repo autonomy.

## Directory Structure After Init

`init` generates coordination directories in the meta-context root:

- `+-contracts/`: cross-repo interfaces and contracts
- `+-docs/`: architecture, integration notes, and generated overviews
- `+-tests/`: integration test setup and shared test assets
- `+-skills/`: company and project specific skills (`skill.md`) with optional colocated helper scripts
- `mcrepo.yaml`: source of truth for repos, modes, descriptions, and branch
- `AGENTS.md`: generated workspace instructions that enforce mode gates and proactively point agents to RepoMapper MCP for codebase overview and Playwright for browser validation when available

Design ordering principle:

- Repositories use clean top-level names.
- Shared folders (`+-contracts`, `+-docs`, `+-tests`, `+-skills`) are created directly at the top level.
- The `+-` prefix is ASCII-only and shell-friendly (no quoting needed). VS Code shows emoji badges (🧩 🧾 🧪 🧠) next to each folder when the mcrepo plugin is installed.
- The old visual separator directory is no longer created. Legacy schemes (`🧪 tests/`, `tests/`, etc.) are migrated automatically on `init`.

## Skills and Workspace Governance

Use `mcrepo` skill commands to manage workspace-local skill packs:

```bash
mcrepo skill list
mcrepo skill new <skill-id>
mcrepo skill install <github-url>
mcrepo skill install <clawhub-url>
mcrepo skill <repo-name> install <github-url|clawhub-url>
mcrepo skill enable <skill-id>
mcrepo skill disable <skill-id>
mcrepo skill validate
```

Skill source support:

- GitHub URLs are supported for direct skill import.
- ClawHub URLs are supported and scanned through Gen Agent Trust Hub before install.
- Recommended public skill directory: `https://clawhub.ai/skills`

ClawHub scan policy defaults:

- `CRITICAL` scan severity blocks install.
- `HIGH` scan severity warns and continues.
- Use `--skip-scan` to bypass scanner checks.
- Use `--require-scan` to fail when scan cannot be performed.

Activation behavior:

- If `+-skills/skills.yaml` exists, enable/disable state is taken from that file.
- If `+-skills/skills.yaml` is missing, every `+-skills/<id>/skill.md` is treated as active.
- MC workspace skills are mirrored into `.opencode/skills/` so OpenCode can auto-discover them.
- For sub-repositories, use standard `.opencode/skills/` (no emoji folder) for local skill installs.

Skill layout (colocated docs + helpers):

```text
+-skills/
  skills.yaml
  _templates/
    skill-template.md
  change-implementation/
    skill.md
    run.sh   # optional helper
```

Authoring notes:

- Keep each skill self-contained in `+-skills/<id>/`.
- Put process and guardrails in `skill.md`.
- Put optional executable helpers (`run.sh`, `check.sh`) next to `skill.md`.
- Use lowercase kebab-case skill IDs (for example: `release-prep`, `test-gate`).

Default skill pack created during `init`:

- `change-implementation`
- `test-gate` (includes Playwright guidance for web-facing validation when available)
- `release-prep`
- `no-secrets`
- `subproject-skill-loader` (loads sub-repo local skills only for write/change scope)

These are starter skills meant to be edited or replaced with your company-specific workflows.

## AI-Agent-First Starter Tasks

After adding repositories, useful first tasks are:

1. Ask your agent to scan all `read` repos and write an interface map into `+-docs/`.
2. Ask your agent to scaffold an integration test setup (for example Docker Compose) in `+-tests/`.
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

- `init` always uses clean repo folder names:

```bash
./mcrepo.sh init
```


## Versioning and Self-Update

- `mcrepo version` prints the version; a banner also goes to **stderr** on every run (stdout stays clean for scripting).
- `mcrepo` checks the canonical upstream script (`GeektankLabs/mcrepo`, `main`, `mcrepo.sh`) at most **once per 24h** (cached in `~/.mcrepo-update-check`) and notifies you when a newer version exists.
- Run `mcrepo update` to self-update the script in place. The download is syntax-validated (`bash -n`) and staged next to the script before an atomic rename; file permissions and symlinks are preserved.
- After updating, a migration hook brings `mcrepo.yaml` to the current manifest schema automatically.
- Override the update source URL (for forks/mirrors) with `MCREPO_UPDATE_URL`.
- Disable automatic update checks with `MCREPO_DISABLE_UPDATE_CHECK=1`.

## Patch Submission Without Repository Checkout

- Run `mcrepo create-patch [--strategy intent|legacy] [topic]` (`export-patch` still works as a deprecated alias).
- Default strategy is `intent`: mcrepo tries to carry only your feature intent onto current upstream and avoid rollback-style hunks.
- Use `--strategy legacy` to force raw `upstream-main vs local-file` diff behavior.
- If you omit `[topic]` in an interactive terminal, mcrepo asks for a short 2-5 word title and supports Enter for a default `Feature update <timestamp>` title.
- When `[topic]` is omitted and mcrepo prompts you, it pauses after the instructions and waits for Enter before printing issue title/body content.
- The command prints everything to stdout:
  - submission steps and issue URL
  - issue title
  - full issue body with embedded `mcrepo.sh` patch against canonical upstream
- Open a new issue, use title prefix `[PATCH SUBMISSION]`, paste the printed issue body, and submit.

## Platforms

- macOS (stock bash 3.2 supported) and Linux — both run in CI on every change.

## mcrepo.yaml Reference

`mcrepo.yaml` is machine-owned: mcrepo rewrites it on every change (comments are not preserved). Schema:

```yaml
schema: 1                     # manifest format version (checked on load)
organization: my-org          # optional: GitHub org for 'init <organization>' sync
branch: feature-x             # optional: the active global (coordinated) branch
meta-parent: main             # parent-branch stack of the meta-context (comma-separated, rightmost = immediate parent)
meta-upstream: <url>          # optional: PR target for the meta-context itself
repos:
  - url: https://github.com/acme/service-a.git   # origin (absent for local incubators)
    name: service-a
    mode: read                # read | write | sleep
    description: "..."        # one-line functional description (agent-maintained)
    parent: main              # parent-branch stack (recorded by 'mcrepo branch')
    upstream: <url>           # optional: PR target for the fork workflow
    local: true               # local incubator repo (no external remote yet)
    localpath: ./service-a
```

Accepted URL transports: `https`, `ssh`, `git`, `file`, absolute/relative local paths, and scp-style `user@host:path`. Anything else (e.g. `ext::`) is rejected — the manifest is a shared file and must not be able to run commands on clone.

## Environment Variables

- `MCREPO_UPDATE_URL` — override the self-update source (forks/mirrors)
- `MCREPO_DISABLE_UPDATE_CHECK=1` — disable the (24h-cached) update check
- `MCREPO_SUPPRESS_VERSION_BANNER=1` — suppress the stderr version banner
- `MCREPO_NO_SHELL_INSTALL=1` — behave like `init --no-shell-install`
- `MCREPO_SKIP_VSCODE=1` — skip VS Code extension install and window reloads (CI/tests)
- `MCREPO_ASSUME_YES=1` — answer every confirmation prompt with yes (CI escape hatch)

## Exit Codes

- `0` — success, including a user-declined confirmation
- `1` — fatal or usage error
- `2` — partial failure (some repos succeeded, some failed) — returned by `pull`, `push`, `pr`

## Glossary

- **meta-context repo** — the workspace root holding `mcrepo.yaml` and the `+-` support folders; participates in coordinated commands as `(meta-context)` when git-managed
- **sub-repo** — an independent git repository managed inside the workspace
- **mode** — per-repo intent signal: `read` (context only), `write` (active changes), `sleep` (clone removed, entry kept)
- **global branch** — one coordinated branch name across target repos, set by `mcrepo branch <name>`
- **parent (stack)** — the branch a feature branch forked from; stacked (comma-separated) so nested branches merge back level by level
- **local incubator** — a repo created by `mcrepo new` that lives committed inside the meta-context until `mcrepo publish` graduates it to its own remote
- **upstream** — the PR target in the fork workflow (origin = your fork, upstream = the original repo)
- **coordinated commit `#N @batch`** — one logical change committed across several repos with a shared sequence number and batch id

## Upgrading from 0.5.x

0.6.0 is a harmonization release with deliberate breaking changes:

- **Removed**: the undocumented `off` command alias (use `sleep`) and `branch off` (use `branch --off`). `mode: off` in old manifests still migrates to `sleep` automatically.
- **Renamed**: `export-patch` → `create-patch` (the old name still works but warns).
- **Output contract**: the version banner and update notices moved to **stderr**; parse stdout freely. Partial per-repo failures now exit `2` (previously often `0`).
- **Prompts**: one contract everywhere — only `y`/`yes` confirms, Enter takes the shown default, anything else declines. Non-interactive runs take the default; destructive actions then need `--yes`/`--force`.
- **sleep** now refuses to delete clones containing *any* local work (unpushed commits on any branch, stashes, read-mode edits) — previously only dirty write-mode repos were guarded. Use `--force` to discard.
- **pull --reset** now asks per repo before discarding committed-but-unpushed commits (previously silent for clean-but-diverged repos). Use `--yes` in automation.
- **commit --revert** now requires branch alignment and matching batch ids across the peel group (override with `--force`).
- **Manifest**: `mcrepo.yaml` gains a `schema: 1` line; repo/upstream URLs are validated against a transport allowlist.
- **Pre-0.5 migrations removed**: emoji-prefixed folder renames (`🧪 tests` → `+-tests` etc.), separator-dir cleanup, and legacy `.gitignore` scrubbing are gone. Coming from a pre-0.5 layout? Run any 0.5.x `mcrepo init` once before updating.
- **New**: `merge --include-read` and `push --include-read` complete the include-read workflow; `branch --dirty abort|commit|carry|discard` makes dirty handling scriptable; `pull --yes`; `mcrepo version`; update checks are cached for 24h.

## Origins

The approach comes from practical maintainer experience in multi-repository open-source work, including the RaspiBlitz ecosystem.
