import * as vscode from 'vscode';
import * as path from 'path';
import { execSync } from 'child_process';
import { findExecutable } from '../utils/paths';

interface BuildTarget {
    name: string;
    type: 'executable' | 'library' | 'test' | 'custom';
    language: string;
    sources: string[];
    deps: string[];
    line?: number;
}

export class BuilderTargetsProvider implements vscode.TreeDataProvider<TargetTreeItem> {
    private _onDidChangeTreeData = new vscode.EventEmitter<TargetTreeItem | undefined | null | void>();
    readonly onDidChangeTreeData = this._onDidChangeTreeData.event;

    private targets: BuildTarget[] = [];
    private context: vscode.ExtensionContext;

    constructor(context: vscode.ExtensionContext) {
        this.context = context;
        this.refresh();
    }

    refresh(): void {
        this.loadTargets();
        this._onDidChangeTreeData.fire();
    }

    getTreeItem(element: TargetTreeItem): vscode.TreeItem {
        return element;
    }

    getChildren(element?: TargetTreeItem): Thenable<TargetTreeItem[]> {
        if (!element) {
            return Promise.resolve(this.getRootItems());
        }
        return Promise.resolve(this.getChildItems(element));
    }

    private getRootItems(): TargetTreeItem[] {
        if (this.targets.length === 0) {
            return [];
        }

        // Group targets by type
        const byType = new Map<string, BuildTarget[]>();
        for (const target of this.targets) {
            const type = target.type;
            if (!byType.has(type)) {
                byType.set(type, []);
            }
            byType.get(type)!.push(target);
        }

        // Create category items
        const items: TargetTreeItem[] = [];
        const typeIcons: Record<string, string> = {
            executable: 'symbol-method',
            library: 'library',
            test: 'beaker',
            custom: 'gear'
        };

        for (const [type, targets] of byType) {
            const categoryItem = new TargetTreeItem(
                `${type.charAt(0).toUpperCase() + type.slice(1)}s`,
                vscode.TreeItemCollapsibleState.Expanded,
                'category'
            );
            categoryItem.iconPath = new vscode.ThemeIcon(typeIcons[type] || 'folder');
            categoryItem.targets = targets;
            items.push(categoryItem);
        }

        return items;
    }

    private getChildItems(element: TargetTreeItem): TargetTreeItem[] {
        if (element.contextValue === 'category' && element.targets) {
            return element.targets.map(target => {
                const item = new TargetTreeItem(
                    target.name,
                    target.deps.length > 0 
                        ? vscode.TreeItemCollapsibleState.Collapsed 
                        : vscode.TreeItemCollapsibleState.None,
                    'target'
                );
                item.description = `${target.language} • ${target.sources.length} source(s)`;
                item.tooltip = this.createTooltip(target);
                item.iconPath = this.getLanguageIcon(target.language);
                item.target = target;
                item.command = {
                    command: 'builder.openTarget',
                    title: 'Open Target',
                    arguments: [target]
                };
                return item;
            });
        }

        if (element.contextValue === 'target' && element.target?.deps.length) {
            return element.target.deps.map(dep => {
                const item = new TargetTreeItem(
                    dep,
                    vscode.TreeItemCollapsibleState.None,
                    'dependency'
                );
                item.iconPath = new vscode.ThemeIcon('references');
                return item;
            });
        }

        return [];
    }

    private createTooltip(target: BuildTarget): vscode.MarkdownString {
        const md = new vscode.MarkdownString();
        md.appendMarkdown(`### ${target.name}\n\n`);
        md.appendMarkdown(`**Type:** ${target.type}\n\n`);
        md.appendMarkdown(`**Language:** ${target.language}\n\n`);
        md.appendMarkdown(`**Sources:** ${target.sources.length} file(s)\n\n`);
        if (target.deps.length > 0) {
            md.appendMarkdown(`**Dependencies:**\n`);
            for (const dep of target.deps) {
                md.appendMarkdown(`- ${dep}\n`);
            }
        }
        return md;
    }

    private getLanguageIcon(language: string): vscode.ThemeIcon {
        const icons: Record<string, string> = {
            python: 'symbol-misc',
            javascript: 'symbol-method',
            typescript: 'symbol-interface',
            rust: 'symbol-class',
            go: 'symbol-module',
            cpp: 'symbol-struct',
            c: 'symbol-struct',
            java: 'coffee',
            ruby: 'ruby',
            elixir: 'symbol-color',
            swift: 'symbol-key'
        };
        return new vscode.ThemeIcon(icons[language.toLowerCase()] || 'file-code');
    }

    private loadTargets(): void {
        const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
        if (!workspaceFolder) {
            this.targets = [];
            return;
        }

        // Try to parse Builderfile directly
        const builderfilePath = path.join(workspaceFolder.uri.fsPath, 'Builderfile');
        try {
            const content = require('fs').readFileSync(builderfilePath, 'utf-8');
            this.targets = this.parseBuilderfile(content);
        } catch {
            // No Builderfile, try CLI query
            this.targets = this.queryTargetsViaCli(workspaceFolder.uri.fsPath);
        }
    }

    private parseBuilderfile(content: string): BuildTarget[] {
        const targets: BuildTarget[] = [];
        const targetRegex = /target\s*\(\s*"([^"]+)"\s*\)\s*\{([^}]+)\}/g;
        let match;

        while ((match = targetRegex.exec(content)) !== null) {
            const name = match[1];
            const body = match[2];

            const target: BuildTarget = {
                name,
                type: this.extractField(body, 'type') as BuildTarget['type'] || 'executable',
                language: this.extractField(body, 'language') || 'unknown',
                sources: this.extractArray(body, 'sources'),
                deps: this.extractArray(body, 'deps')
            };

            // Find line number
            const lines = content.substring(0, match.index).split('\n');
            target.line = lines.length;

            targets.push(target);
        }

        return targets;
    }

    private extractField(body: string, field: string): string {
        const regex = new RegExp(`${field}\\s*:\\s*([^;\\n]+)`);
        const match = body.match(regex);
        return match ? match[1].trim().replace(/[";]/g, '') : '';
    }

    private extractArray(body: string, field: string): string[] {
        const regex = new RegExp(`${field}\\s*:\\s*\\[([^\\]]+)\\]`);
        const match = body.match(regex);
        if (!match) return [];
        return match[1].split(',').map(s => s.trim().replace(/[":]/g, '')).filter(Boolean);
    }

    private queryTargetsViaCli(workspaceDir: string): BuildTarget[] {
        const cliPath = findExecutable('bldr');
        if (!cliPath) return [];

        try {
            const result = execSync(`${cliPath} query --format=json targets`, {
                cwd: workspaceDir,
                encoding: 'utf-8',
                timeout: 5000
            });
            return JSON.parse(result);
        } catch {
            return [];
        }
    }

    getTargets(): BuildTarget[] {
        return this.targets;
    }
}

class TargetTreeItem extends vscode.TreeItem {
    targets?: BuildTarget[];
    target?: BuildTarget;

    constructor(
        label: string,
        collapsibleState: vscode.TreeItemCollapsibleState,
        public readonly contextValue: string
    ) {
        super(label, collapsibleState);
    }
}

