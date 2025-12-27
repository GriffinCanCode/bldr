import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';

interface CacheStats {
    totalSize: string;
    entries: number;
    hitRate: string;
    lastClean: string;
}

export class CacheStatusProvider implements vscode.TreeDataProvider<CacheTreeItem> {
    private _onDidChangeTreeData = new vscode.EventEmitter<CacheTreeItem | undefined>();
    readonly onDidChangeTreeData = this._onDidChangeTreeData.event;

    private stats: CacheStats | null = null;

    constructor() {
        this.loadCacheStats();
    }

    refresh(): void {
        this.loadCacheStats();
        this._onDidChangeTreeData.fire(undefined);
    }

    getTreeItem(element: CacheTreeItem): vscode.TreeItem {
        return element;
    }

    getChildren(): Thenable<CacheTreeItem[]> {
        if (!this.stats) {
            const item = new CacheTreeItem('No cache data', vscode.TreeItemCollapsibleState.None);
            item.iconPath = new vscode.ThemeIcon('warning');
            return Promise.resolve([item]);
        }

        const items: CacheTreeItem[] = [
            this.createStatItem('Size', this.stats.totalSize, 'database'),
            this.createStatItem('Entries', String(this.stats.entries), 'list-flat'),
            this.createStatItem('Hit Rate', this.stats.hitRate, 'graph'),
            this.createStatItem('Last Clean', this.stats.lastClean, 'history')
        ];

        return Promise.resolve(items);
    }

    private createStatItem(label: string, value: string, icon: string): CacheTreeItem {
        const item = new CacheTreeItem(label, vscode.TreeItemCollapsibleState.None);
        item.description = value;
        item.iconPath = new vscode.ThemeIcon(icon);
        return item;
    }

    private loadCacheStats(): void {
        const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
        if (!workspaceFolder) {
            this.stats = null;
            return;
        }

        const cacheDir = path.join(workspaceFolder.uri.fsPath, '.builder-cache');
        if (!fs.existsSync(cacheDir)) {
            this.stats = null;
            return;
        }

        try {
            // Calculate cache size
            const size = this.getDirSize(cacheDir);
            const entries = this.countEntries(cacheDir);
            
            // Try to read stats file
            const statsFile = path.join(cacheDir, 'stats.json');
            let hitRate = 'N/A';
            let lastClean = 'Never';

            if (fs.existsSync(statsFile)) {
                const statsData = JSON.parse(fs.readFileSync(statsFile, 'utf-8'));
                if (statsData.hits !== undefined && statsData.misses !== undefined) {
                    const total = statsData.hits + statsData.misses;
                    hitRate = total > 0 ? `${Math.round((statsData.hits / total) * 100)}%` : 'N/A';
                }
                if (statsData.lastClean) {
                    lastClean = new Date(statsData.lastClean).toLocaleDateString();
                }
            }

            this.stats = {
                totalSize: this.formatSize(size),
                entries,
                hitRate,
                lastClean
            };
        } catch {
            this.stats = null;
        }
    }

    private getDirSize(dir: string): number {
        let size = 0;
        try {
            const items = fs.readdirSync(dir, { withFileTypes: true });
            for (const item of items) {
                const fullPath = path.join(dir, item.name);
                if (item.isDirectory()) {
                    size += this.getDirSize(fullPath);
                } else {
                    size += fs.statSync(fullPath).size;
                }
            }
        } catch {
            // Ignore errors
        }
        return size;
    }

    private countEntries(dir: string): number {
        let count = 0;
        try {
            const items = fs.readdirSync(dir, { withFileTypes: true });
            for (const item of items) {
                if (item.isDirectory() && item.name !== 'stats') {
                    count += fs.readdirSync(path.join(dir, item.name)).length;
                }
            }
        } catch {
            // Ignore errors
        }
        return count;
    }

    private formatSize(bytes: number): string {
        const units = ['B', 'KB', 'MB', 'GB'];
        let i = 0;
        let size = bytes;
        while (size >= 1024 && i < units.length - 1) {
            size /= 1024;
            i++;
        }
        return `${size.toFixed(1)} ${units[i]}`;
    }
}

class CacheTreeItem extends vscode.TreeItem {
    constructor(label: string, collapsibleState: vscode.TreeItemCollapsibleState) {
        super(label, collapsibleState);
    }
}

