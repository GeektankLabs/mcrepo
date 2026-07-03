# mcrepo (Multi-Context) VS Code Extension

Adds Explorer decorations and right-click mode switches for mcrepo workspaces without changing real folder names.

The extension only activates in workspaces that contain an `mcrepo.yaml` (activation event `workspaceContains:mcrepo.yaml`); it never writes settings or shows menus in unrelated projects.

## What it does

- Decorates repo folders from `mcrepo.yaml` with mode badges:
  - `✏️` for `write`
  - `👀` for `read`
  - `💤` for `sleep`
- Decorates the `+-contracts` / `+-docs` / `+-tests` / `+-skills` support folders with their emoji badges (🧩 🧾 🧪 🧠).
- Ensures the workspace SCM settings mcrepo relies on (`scm.alwaysShowRepositories`, `scm.repositories.selectionMode`, `git.autoRepositoryDetection`, `git.repositoryScanMaxDepth`) — only when they are unset, and only in mcrepo workspaces.
- Watches `mcrepo.yaml` and updates decorations when it changes; on SCM-relevant topology changes (new repo, `sleep <-> read/write`) it prompts to reload the window.

## Explorer context actions

On a top-level sub-repo folder in Explorer, right-click and use:

- `🗂 ✏️ Set Write`
- `🗂 👀 Set Read`
- `🗂 💤 Set Sleep`

`Set Sleep` asks for confirmation. These menu items appear only in mcrepo workspaces.

## Commands

- `mcrepo (Multi-Context): Refresh Decorations`

## Install

The recommended path is `mcrepo install-extension` (or `mcrepo init`, which installs it automatically when the `code` CLI is available). Manual install:

```bash
code --install-extension vsc-plugin/mcrepo.vsix --force
```

## Local development

```bash
cd vsc-plugin
npm ci
npm run compile
```

Open `vsc-plugin` in VS Code and press `F5` to launch an Extension Development Host.

## Build the `.vsix`

```bash
cd vsc-plugin
./build.sh          # npm ci + compile + vsce package -> mcrepo.vsix
```

Version rule: any change under `src/` or to `package.json` must bump the `version` field in `package.json` (see `AGENTS.md` in the repo root).
