# mcrepo (Multi-Context) VS Code Extension

Adds Explorer decorations and right-click mode switches for mcrepo workspaces without changing real folder names.

## What it decorates

- Repo folders from `mcrepo.yaml` with mode badges:
- `✏️` for `write`
  - `👀` for `read`
  - `💤` for `sleep`

Support folders (`docs`, `tests`, `skills`, `contracts`) are intentionally not decorated to avoid duplicate icon display.

The extension reads `mcrepo.yaml` and updates decorations when the file changes.

## Explorer context actions

On a top-level sub-repo folder in Explorer, right-click and use:

- `🗂 ✏️ Set Write`
- `🗂 👀 Set Read`
- `🗂 💤 Set Sleep`

`Set Sleep` asks for confirmation.

## Local development

```bash
cd vsc-plugin
npm install
npm run compile
```

Open `vsc-plugin` in VS Code and press `F5` to launch an Extension Development Host.

## Package `.vsix`

```bash
cd vsc-plugin
npm install
npm run compile
npm run package
```

This creates:

- `vsc-plugin/mcrepo-multi-context-0.0.4.vsix`

## Install the extension

Option A (VS Code UI):

- Command Palette -> `Extensions: Install from VSIX...`
- Choose `vsc-plugin/mcrepo-multi-context-0.0.4.vsix`

Option B (CLI):

```bash
code --install-extension "vsc-plugin/mcrepo-multi-context-0.0.4.vsix"
```

## Rebuild after changes

If you change extension code, rebuild and reinstall:

```bash
cd vsc-plugin
npm run compile
npm run package
code --install-extension "mcrepo-multi-context-0.0.4.vsix" --force
```

## Command

- `MCRepo Decorations: Refresh`
