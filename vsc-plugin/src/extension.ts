import * as vscode from "vscode";
import * as path from "node:path";
import { parse } from "yaml";

type FolderDecoration = {
  badge: string;
  tooltip: string;
};

type RepoEntry = {
  name?: string;
  mode?: string;
  localpath?: string;
};

type McrepoConfig = {
  path_style?: string;
  repos?: RepoEntry[];
};

const REPOS_FILE = "mcrepo.yaml";

const MODE_BADGES: Record<string, string> = {
  write: "✍️",
  read: "👀",
  sleep: "💤"
};

const SUPPORT_FOLDERS: Array<{ names: string[]; badge: string; label: string }> = [
  { names: ["🧩 contracts", "contracts"], badge: "🧩", label: "contracts" },
  { names: ["🧾 docs", "docs"], badge: "🧾", label: "docs" },
  { names: ["🧪 tests", "tests"], badge: "🧪", label: "tests" },
  { names: ["🧠 skills", "skills"], badge: "🧠", label: "skills" }
];

class McrepoDecorationProvider implements vscode.FileDecorationProvider {
  private readonly onDidChangeEmitter = new vscode.EventEmitter<vscode.Uri[]>();
  readonly onDidChangeFileDecorations = this.onDidChangeEmitter.event;

  private readonly output = vscode.window.createOutputChannel("MCRepo Decorations");
  private readonly decorationsByWorkspace = new Map<string, Map<string, FolderDecoration>>();
  private readonly disposables: vscode.Disposable[] = [];

  constructor(private readonly context: vscode.ExtensionContext) {
    this.disposables.push(vscode.window.registerFileDecorationProvider(this));
    this.disposables.push(
      vscode.commands.registerCommand("mcrepoDecorations.refresh", async () => {
        await this.reloadAll();
        vscode.window.setStatusBarMessage("MCRepo decorations refreshed", 2000);
      })
    );
    this.disposables.push(
      vscode.workspace.onDidChangeWorkspaceFolders(async () => {
        await this.reloadAll();
      })
    );

    for (const workspaceFolder of vscode.workspace.workspaceFolders ?? []) {
      this.registerWorkspaceWatcher(workspaceFolder);
    }

    this.disposables.push(
      vscode.workspace.onDidChangeWorkspaceFolders((event) => {
        for (const added of event.added) {
          this.registerWorkspaceWatcher(added);
        }
      })
    );
  }

  async reloadAll(): Promise<void> {
    const changedUris: vscode.Uri[] = [];
    const folders = vscode.workspace.workspaceFolders ?? [];

    for (const folder of folders) {
      const workspaceKey = folder.uri.toString();
      const before = this.decorationsByWorkspace.get(workspaceKey) ?? new Map<string, FolderDecoration>();
      const after = await this.loadDecorationsForWorkspace(folder);
      this.decorationsByWorkspace.set(workspaceKey, after);
      changedUris.push(...this.collectChangedUris(folder, before, after));
    }

    const validKeys = new Set(folders.map((folder) => folder.uri.toString()));
    for (const [workspaceKey, oldMap] of this.decorationsByWorkspace.entries()) {
      if (validKeys.has(workspaceKey)) {
        continue;
      }
      this.decorationsByWorkspace.delete(workspaceKey);
      const removedRoot = vscode.Uri.parse(workspaceKey);
      for (const relativePath of oldMap.keys()) {
        changedUris.push(vscode.Uri.joinPath(removedRoot, relativePath));
      }
    }

    if (changedUris.length > 0) {
      this.onDidChangeEmitter.fire(changedUris);
    }
  }

  provideFileDecoration(uri: vscode.Uri): vscode.ProviderResult<vscode.FileDecoration> {
    const folder = vscode.workspace.getWorkspaceFolder(uri);
    if (!folder) {
      return undefined;
    }

    const relativePath = this.getTopLevelRelativePath(folder, uri);
    if (!relativePath) {
      return undefined;
    }

    const workspaceDecorations = this.decorationsByWorkspace.get(folder.uri.toString());
    if (!workspaceDecorations) {
      return undefined;
    }

    const decoration = workspaceDecorations.get(relativePath);
    if (!decoration) {
      return undefined;
    }

    return new vscode.FileDecoration(decoration.badge, decoration.tooltip);
  }

  dispose(): void {
    this.onDidChangeEmitter.dispose();
    this.output.dispose();
    vscode.Disposable.from(...this.disposables).dispose();
  }

  private registerWorkspaceWatcher(workspaceFolder: vscode.WorkspaceFolder): void {
    const pattern = new vscode.RelativePattern(workspaceFolder, REPOS_FILE);
    const watcher = vscode.workspace.createFileSystemWatcher(pattern);
    const reload = this.debounce(async () => {
      await this.reloadAll();
    }, 200);

    watcher.onDidCreate(reload);
    watcher.onDidChange(reload);
    watcher.onDidDelete(reload);

    this.disposables.push(watcher);
  }

  private async loadDecorationsForWorkspace(workspaceFolder: vscode.WorkspaceFolder): Promise<Map<string, FolderDecoration>> {
    const map = new Map<string, FolderDecoration>();
    this.addSupportFolderDecorations(map);

    const reposUri = vscode.Uri.joinPath(workspaceFolder.uri, REPOS_FILE);
    let rawContent: Uint8Array;
    try {
      rawContent = await vscode.workspace.fs.readFile(reposUri);
    } catch {
      return map;
    }

    const content = new TextDecoder("utf-8").decode(rawContent);
    let config: McrepoConfig;
    try {
      config = parse(content) as McrepoConfig;
    } catch (error) {
      this.output.appendLine(`Could not parse ${REPOS_FILE} in ${workspaceFolder.name}: ${String(error)}`);
      return map;
    }

    if (!config || !Array.isArray(config.repos)) {
      return map;
    }

    const pathStyle = typeof config.path_style === "string" ? config.path_style : "emoji";

    for (const repo of config.repos) {
      const mode = this.normalizeMode(repo.mode);
      const modeBadge = MODE_BADGES[mode];
      if (!modeBadge) {
        continue;
      }

      const candidatePaths = this.resolveRepoFolderCandidates(repo, pathStyle, mode);
      const tooltip = `mcrepo repo mode: ${mode}`;
      for (const relativePath of candidatePaths) {
        map.set(relativePath, { badge: modeBadge, tooltip });
      }
    }

    return map;
  }

  private addSupportFolderDecorations(map: Map<string, FolderDecoration>): void {
    for (const folder of SUPPORT_FOLDERS) {
      for (const name of folder.names) {
        map.set(name, {
          badge: folder.badge,
          tooltip: `mcrepo support folder: ${folder.label}`
        });
      }
    }
  }

  private resolveRepoFolderCandidates(repo: RepoEntry, pathStyle: string, mode: string): string[] {
    const candidates = new Set<string>();

    const localPath = this.topLevelName(repo.localpath);
    if (localPath) {
      candidates.add(localPath);
    }

    const repoName = (repo.name ?? "").trim();
    if (!repoName) {
      return [...candidates];
    }

    if (pathStyle === "clean") {
      candidates.add(repoName);
      candidates.add(`${MODE_BADGES[mode]} ${repoName}`);
    } else {
      candidates.add(`${MODE_BADGES[mode]} ${repoName}`);
      candidates.add(repoName);
    }

    return [...candidates];
  }

  private normalizeMode(mode: string | undefined): string {
    if (!mode) {
      return "read";
    }
    if (mode === "off") {
      return "sleep";
    }
    if (mode in MODE_BADGES) {
      return mode;
    }
    return "read";
  }

  private topLevelName(localpath: string | undefined): string | undefined {
    if (!localpath) {
      return undefined;
    }

    const normalized = localpath.replace(/\\/g, "/").replace(/^\.\//, "").replace(/^\//, "").trim();
    if (!normalized) {
      return undefined;
    }

    const firstSegment = normalized.split("/")[0]?.trim();
    return firstSegment || undefined;
  }

  private getTopLevelRelativePath(folder: vscode.WorkspaceFolder, uri: vscode.Uri): string | undefined {
    const relativePath = path.posix.relative(folder.uri.path, uri.path);
    if (!relativePath || relativePath.startsWith("..") || path.posix.isAbsolute(relativePath)) {
      return undefined;
    }

    if (relativePath.includes("/")) {
      return undefined;
    }

    return relativePath;
  }

  private collectChangedUris(
    workspaceFolder: vscode.WorkspaceFolder,
    before: Map<string, FolderDecoration>,
    after: Map<string, FolderDecoration>
  ): vscode.Uri[] {
    const changed = new Set<string>();

    for (const [relativePath, previous] of before.entries()) {
      const next = after.get(relativePath);
      if (!next || next.badge !== previous.badge || next.tooltip !== previous.tooltip) {
        changed.add(relativePath);
      }
    }

    for (const relativePath of after.keys()) {
      if (!before.has(relativePath)) {
        changed.add(relativePath);
      }
    }

    return [...changed].map((relativePath) => vscode.Uri.joinPath(workspaceFolder.uri, relativePath));
  }

  private debounce(fn: () => void | Promise<void>, delayMs: number): () => void {
    let timeout: NodeJS.Timeout | undefined;
    return () => {
      if (timeout) {
        clearTimeout(timeout);
      }
      timeout = setTimeout(() => {
        void fn();
      }, delayMs);
    };
  }
}

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  const provider = new McrepoDecorationProvider(context);
  context.subscriptions.push(provider);
  await provider.reloadAll();
}

export function deactivate(): void {
  // all disposables are registered on activation context
}
