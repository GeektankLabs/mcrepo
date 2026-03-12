# MCRepo Decorations (VS Code Extension)

Adds Explorer decorations for mcrepo workspaces without changing real folder names.

## What it decorates

- Repo folders from `mcrepo.yaml` with mode badges:
  - `✍️` for `write`
  - `👀` for `read`
  - `💤` for `sleep`
- Support folders with badges:
  - `🧩` contracts
  - `🧾` docs
  - `🧪` tests
  - `🧠` skills

The extension reads `mcrepo.yaml` and updates decorations when the file changes.

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

- `vsc-plugin/mcrepo-decorations-0.0.1.vsix`

## Install the extension

Option A (VS Code UI):

- Command Palette -> `Extensions: Install from VSIX...`
- Choose `vsc-plugin/mcrepo-decorations-0.0.1.vsix`

Option B (CLI):

```bash
code --install-extension "vsc-plugin/mcrepo-decorations-0.0.1.vsix"
```

## Rebuild after changes

If you change extension code, rebuild and reinstall:

```bash
cd vsc-plugin
npm run compile
npm run package
code --install-extension "mcrepo-decorations-0.0.1.vsix" --force
```

## Command

- `MCRepo Decorations: Refresh`
