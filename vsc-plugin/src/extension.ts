import * as vscode from "vscode";
import * as path from "node:path";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { promisify } from "node:util";
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
  repos?: RepoEntry[];
};

type RepoMode = "write" | "read" | "sleep";

type WorkspaceDecorations = {
  decorations: Map<string, FolderDecoration>;
  repoNameByPath: Map<string, string>;
  repoSnapshot: Map<string, RepoSnapshotEntry>;
};

type RepoSnapshotEntry = {
  mode: RepoMode;
  localpath?: string;
};

const REPOS_FILE = "mcrepo.yaml";
const VSCODE_SETTINGS_FILE = ".vscode/settings.json";
const execFileAsync = promisify(execFile);

const MODE_BADGES: Record<string, string> = {
  write: "✏️",
  read: "👀",
  sleep: "💤"
};

class McrepoDecorationProvider implements vscode.FileDecorationProvider {
  private readonly onDidChangeEmitter = new vscode.EventEmitter<vscode.Uri[]>();
  readonly onDidChangeFileDecorations = this.onDidChangeEmitter.event;

  private readonly output = vscode.window.createOutputChannel("MCRepo Decorations");
  private readonly decorationsByWorkspace = new Map<string, Map<string, FolderDecoration>>();
  private readonly repoNameByWorkspacePath = new Map<string, Map<string, string>>();
  private readonly repoSnapshotByWorkspace = new Map<string, Map<string, RepoSnapshotEntry>>();
  private readonly initializedWorkspaces = new Set<string>();
  private readonly refreshPromptPending = new Set<string>();
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
      vscode.commands.registerCommand("mcrepoDecorations.setWrite", async (uri: vscode.Uri) => {
        await this.switchRepoModeFromExplorer(uri, "write");
      })
    );
    this.disposables.push(
      vscode.commands.registerCommand("mcrepoDecorations.setRead", async (uri: vscode.Uri) => {
        await this.switchRepoModeFromExplorer(uri, "read");
      })
    );
    this.disposables.push(
      vscode.commands.registerCommand("mcrepoDecorations.setSleep", async (uri: vscode.Uri) => {
        await this.switchRepoModeFromExplorer(uri, "sleep");
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
      const beforeSnapshot = this.repoSnapshotByWorkspace.get(workspaceKey) ?? new Map<string, RepoSnapshotEntry>();
      const workspaceDecorations = await this.loadDecorationsForWorkspace(folder);
      this.decorationsByWorkspace.set(workspaceKey, workspaceDecorations.decorations);
      this.repoNameByWorkspacePath.set(workspaceKey, workspaceDecorations.repoNameByPath);
      this.repoSnapshotByWorkspace.set(workspaceKey, workspaceDecorations.repoSnapshot);
      changedUris.push(...this.collectChangedUris(folder, before, workspaceDecorations.decorations));

      if (this.initializedWorkspaces.has(workspaceKey)) {
        const reasons = this.detectScmRefreshReasons(beforeSnapshot, workspaceDecorations.repoSnapshot);
        if (reasons.length > 0) {
          void this.promptScmRefresh(folder, reasons);
        }
      } else {
        this.initializedWorkspaces.add(workspaceKey);
      }
    }

    const validKeys = new Set(folders.map((folder) => folder.uri.toString()));
    for (const [workspaceKey, oldMap] of this.decorationsByWorkspace.entries()) {
      if (validKeys.has(workspaceKey)) {
        continue;
      }
      this.decorationsByWorkspace.delete(workspaceKey);
      this.repoNameByWorkspacePath.delete(workspaceKey);
      this.repoSnapshotByWorkspace.delete(workspaceKey);
      this.initializedWorkspaces.delete(workspaceKey);
      this.refreshPromptPending.delete(workspaceKey);
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
    const reposPattern = new vscode.RelativePattern(workspaceFolder, REPOS_FILE);
    const settingsPattern = new vscode.RelativePattern(workspaceFolder, VSCODE_SETTINGS_FILE);
    const reposWatcher = vscode.workspace.createFileSystemWatcher(reposPattern);
    const settingsWatcher = vscode.workspace.createFileSystemWatcher(settingsPattern);
    const reload = this.debounce(async () => {
      await this.reloadAll();
    }, 200);

    reposWatcher.onDidCreate(reload);
    reposWatcher.onDidChange(reload);
    reposWatcher.onDidDelete(reload);

    settingsWatcher.onDidCreate(reload);
    settingsWatcher.onDidChange(reload);
    settingsWatcher.onDidDelete(reload);

    this.disposables.push(reposWatcher, settingsWatcher);
  }

  private async switchRepoModeFromExplorer(uri: vscode.Uri | undefined, targetMode: RepoMode): Promise<void> {
    if (!uri) {
      void vscode.window.showWarningMessage("Please run this command from a repository folder in Explorer.");
      return;
    }

    const folder = vscode.workspace.getWorkspaceFolder(uri);
    if (!folder) {
      void vscode.window.showWarningMessage("Selected folder is not in an active workspace.");
      return;
    }

    const relativePath = this.getTopLevelRelativePath(folder, uri);
    if (!relativePath) {
      void vscode.window.showWarningMessage("Please select a top-level mcrepo repository folder.");
      return;
    }

    const repoNameByPath = this.repoNameByWorkspacePath.get(folder.uri.toString());
    const repoName = repoNameByPath?.get(relativePath);
    if (!repoName) {
      void vscode.window.showWarningMessage(`'${path.posix.basename(relativePath)}' is not a managed repository in mcrepo.yaml.`);
      return;
    }

    if (targetMode === "sleep") {
      const choice = await vscode.window.showWarningMessage(
        `Set '${repoName}' to Sleep mode?`,
        { modal: true, detail: "Sleep mode can clear local repository contents depending on your mcrepo workflow." },
        "Set Sleep"
      );
      if (choice !== "Set Sleep") {
        return;
      }
    }

    try {
      await this.runMcrepoModeCommand(folder, repoName, targetMode);
      await this.reloadAll();
      void vscode.window.setStatusBarMessage(`mcrepo: '${repoName}' set to ${targetMode}`, 2500);
    } catch (error) {
      this.output.show(true);
      this.output.appendLine(String(error));
      void vscode.window.showErrorMessage(`Failed to set '${repoName}' to ${targetMode}. See 'MCRepo Decorations' output.`);
    }
  }

  private async runMcrepoModeCommand(
    workspaceFolder: vscode.WorkspaceFolder,
    repoName: string,
    targetMode: RepoMode
  ): Promise<void> {
    const cwd = workspaceFolder.uri.fsPath;
    const localScriptPath = path.join(cwd, "mcrepo.sh");
    const args = [targetMode, repoName];

    let cmd = "mcrepo";
    let cmdArgs = args;
    if (existsSync(localScriptPath)) {
      cmd = "bash";
      cmdArgs = [localScriptPath, ...args];
    }

    const { stdout, stderr } = await execFileAsync(cmd, cmdArgs, {
      cwd,
      maxBuffer: 1024 * 1024
    });

    if (stdout.trim()) {
      this.output.appendLine(stdout.trim());
    }
    if (stderr.trim()) {
      this.output.appendLine(stderr.trim());
    }
  }

  private async loadDecorationsForWorkspace(workspaceFolder: vscode.WorkspaceFolder): Promise<WorkspaceDecorations> {
    const map = new Map<string, FolderDecoration>();
    const repoNameByPath = new Map<string, string>();
    const repoSnapshot = new Map<string, RepoSnapshotEntry>();

    const reposUri = vscode.Uri.joinPath(workspaceFolder.uri, REPOS_FILE);
    let rawContent: Uint8Array;
    try {
      rawContent = await vscode.workspace.fs.readFile(reposUri);
    } catch {
      return { decorations: map, repoNameByPath, repoSnapshot };
    }

    const content = new TextDecoder("utf-8").decode(rawContent);
    let config: McrepoConfig;
    try {
      config = parse(content) as McrepoConfig;
    } catch (error) {
      this.output.appendLine(`Could not parse ${REPOS_FILE} in ${workspaceFolder.name}: ${String(error)}`);
      return { decorations: map, repoNameByPath, repoSnapshot };
    }

    if (!config || !Array.isArray(config.repos)) {
      return { decorations: map, repoNameByPath, repoSnapshot };
    }

    for (const repo of config.repos) {
      const mode = this.normalizeMode(repo.mode);
      const modeBadge = MODE_BADGES[mode];
      if (!modeBadge) {
        continue;
      }

      const repoName = (repo.name ?? "").trim();
      if (!repoName) {
        continue;
      }

      repoSnapshot.set(repoName, {
        mode,
        localpath: this.topLevelName(repo.localpath)
      });

      const candidatePaths = this.resolveRepoFolderCandidates(repo);
      const tooltip = `mcrepo repo mode: ${mode}`;
      for (const relativePath of candidatePaths) {
        map.set(relativePath, { badge: modeBadge, tooltip });
        if (!repoNameByPath.has(relativePath)) {
          repoNameByPath.set(relativePath, repoName);
        }
      }
    }

    return { decorations: map, repoNameByPath, repoSnapshot };
  }

  private resolveRepoFolderCandidates(repo: RepoEntry): string[] {
    const candidates = new Set<string>();

    const localPath = this.topLevelName(repo.localpath);
    if (localPath) {
      candidates.add(localPath);
    }

    const repoName = (repo.name ?? "").trim();
    if (!repoName) {
      return [...candidates];
    }

    candidates.add(repoName);

    return [...candidates];
  }

  private normalizeMode(mode: string | undefined): RepoMode {
    if (!mode) {
      return "read";
    }
    if (mode === "off") {
      return "sleep";
    }
    if (mode in MODE_BADGES) {
      return mode as RepoMode;
    }
    return "read";
  }

  private detectScmRefreshReasons(
    before: Map<string, RepoSnapshotEntry>,
    after: Map<string, RepoSnapshotEntry>
  ): string[] {
    const reasons: string[] = [];

    for (const repoName of after.keys()) {
      if (!before.has(repoName)) {
        reasons.push(`new repo added: ${repoName}`);
      }
    }

    for (const [repoName, next] of after.entries()) {
      const prev = before.get(repoName);
      if (!prev) {
        continue;
      }

      const sleepToActive = prev.mode === "sleep" && next.mode !== "sleep";
      const activeToSleep = prev.mode !== "sleep" && next.mode === "sleep";
      if (sleepToActive || activeToSleep) {
        reasons.push(`mode transition ${repoName}: ${prev.mode} -> ${next.mode}`);
      }
    }

    return reasons;
  }

  private async promptScmRefresh(workspaceFolder: vscode.WorkspaceFolder, reasons: string[]): Promise<void> {
    const workspaceKey = workspaceFolder.uri.toString();
    if (this.refreshPromptPending.has(workspaceKey)) {
      return;
    }

    this.refreshPromptPending.add(workspaceKey);
    try {
      this.output.appendLine(`SCM refresh recommended for ${workspaceFolder.name}: ${reasons.join("; ")}`);
      const choice = await vscode.window.showInformationMessage(
        `MCRepo detected repository topology changes. Reload window to refresh Source Control?`,
        "Reload Now",
        "Later"
      );
      if (choice === "Reload Now") {
        await vscode.commands.executeCommand("workbench.action.reloadWindow");
      }
    } finally {
      this.refreshPromptPending.delete(workspaceKey);
    }
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
