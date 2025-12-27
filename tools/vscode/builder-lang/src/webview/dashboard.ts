import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';
import { findExecutable } from '../utils/paths';

export class DashboardPanel {
    public static currentPanel: DashboardPanel | undefined;
    private readonly _panel: vscode.WebviewPanel;
    private readonly _extensionUri: vscode.Uri;
    private _disposables: vscode.Disposable[] = [];

    public static createOrShow(extensionUri: vscode.Uri): void {
        const column = vscode.window.activeTextEditor?.viewColumn;

        if (DashboardPanel.currentPanel) {
            DashboardPanel.currentPanel._panel.reveal(column);
            DashboardPanel.currentPanel._update();
            return;
        }

        const panel = vscode.window.createWebviewPanel(
            'builderDashboard',
            'Builder Dashboard',
            column || vscode.ViewColumn.One,
            {
                enableScripts: true,
                retainContextWhenHidden: true,
                localResourceRoots: [extensionUri]
            }
        );

        DashboardPanel.currentPanel = new DashboardPanel(panel, extensionUri);
    }

    private constructor(panel: vscode.WebviewPanel, extensionUri: vscode.Uri) {
        this._panel = panel;
        this._extensionUri = extensionUri;

        this._update();

        this._panel.onDidDispose(() => this.dispose(), null, this._disposables);

        this._panel.webview.onDidReceiveMessage(
            async (message) => {
                switch (message.command) {
                    case 'build':
                        vscode.commands.executeCommand('builder.build');
                        break;
                    case 'buildTarget':
                        vscode.commands.executeCommand('builder.buildTarget', message.target);
                        break;
                    case 'clean':
                        vscode.commands.executeCommand('builder.clean');
                        break;
                    case 'watch':
                        vscode.commands.executeCommand('builder.watch');
                        break;
                    case 'showGraph':
                        vscode.commands.executeCommand('builder.showGraph');
                        break;
                    case 'generate':
                        vscode.commands.executeCommand('builder.generateBuilderfile');
                        break;
                    case 'refresh':
                        this._update();
                        break;
                }
            },
            null,
            this._disposables
        );

        const watcher = vscode.workspace.createFileSystemWatcher('**/{Builderfile,Builderspace,.builder-cache/**}');
        watcher.onDidChange(() => this._update());
        watcher.onDidCreate(() => this._update());
        watcher.onDidDelete(() => this._update());
        this._disposables.push(watcher);
    }

    public dispose(): void {
        DashboardPanel.currentPanel = undefined;
        this._panel.dispose();
        while (this._disposables.length) {
            this._disposables.pop()?.dispose();
        }
    }

    private async _update(): Promise<void> {
        const webview = this._panel.webview;
        const data = await this._gatherDashboardData();
        webview.html = this._getHtml(webview, data);
    }

    private async _gatherDashboardData(): Promise<DashboardData> {
        const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
        const data: DashboardData = {
            projectName: workspaceFolder?.name || 'Unknown Project',
            hasBuilderfile: false,
            targets: [],
            cacheStats: null,
            recentBuilds: []
        };

        if (!workspaceFolder) return data;

        const wsPath = workspaceFolder.uri.fsPath;
        const builderfilePath = path.join(wsPath, 'Builderfile');
        data.hasBuilderfile = fs.existsSync(builderfilePath);

        if (data.hasBuilderfile) {
            data.targets = this._parseTargets(builderfilePath);
        }

        const cacheDir = path.join(wsPath, '.builder-cache');
        if (fs.existsSync(cacheDir)) {
            data.cacheStats = this._getCacheStats(cacheDir);
        }

        return data;
    }

    private _parseTargets(builderfilePath: string): TargetInfo[] {
        const targets: TargetInfo[] = [];
        try {
            const content = fs.readFileSync(builderfilePath, 'utf-8');
            const regex = /target\s*\(\s*"([^"]+)"\s*\)\s*\{([^}]+)\}/g;
            let match;

            while ((match = regex.exec(content)) !== null) {
                const name = match[1];
                const body = match[2];
                
                const typeMatch = body.match(/type\s*:\s*(\w+)/);
                const langMatch = body.match(/language\s*:\s*(\w+)/);

                targets.push({
                    name,
                    type: typeMatch?.[1] || 'unknown',
                    language: langMatch?.[1] || 'unknown'
                });
            }
        } catch { /* ignore */ }
        return targets;
    }

    private _getCacheStats(cacheDir: string): CacheStats {
        const stats: CacheStats = { size: '0 B', entries: 0, hitRate: 0 };

        try {
            stats.size = this._formatSize(this._getDirSize(cacheDir));
            stats.entries = this._countCacheEntries(cacheDir);

            const statsFile = path.join(cacheDir, 'stats.json');
            if (fs.existsSync(statsFile)) {
                const data = JSON.parse(fs.readFileSync(statsFile, 'utf-8'));
                const total = (data.hits || 0) + (data.misses || 0);
                stats.hitRate = total > 0 ? Math.round((data.hits / total) * 100) : 0;
            }
        } catch { /* ignore */ }

        return stats;
    }

    private _getDirSize(dir: string): number {
        let size = 0;
        try {
            const items = fs.readdirSync(dir, { withFileTypes: true });
            for (const item of items) {
                const fullPath = path.join(dir, item.name);
                size += item.isDirectory() ? this._getDirSize(fullPath) : fs.statSync(fullPath).size;
            }
        } catch { /* ignore */ }
        return size;
    }

    private _countCacheEntries(dir: string): number {
        let count = 0;
        try {
            const items = fs.readdirSync(dir, { withFileTypes: true });
            for (const item of items) {
                if (item.isDirectory() && !item.name.startsWith('.')) {
                    count += fs.readdirSync(path.join(dir, item.name)).length;
                }
            }
        } catch { /* ignore */ }
        return count;
    }

    private _formatSize(bytes: number): string {
        const units = ['B', 'KB', 'MB', 'GB'];
        let i = 0, size = bytes;
        while (size >= 1024 && i < units.length - 1) { size /= 1024; i++; }
        return `${size.toFixed(1)} ${units[i]}`;
    }

    private _getHtml(_webview: vscode.Webview, data: DashboardData): string {
        const nonce = getNonce();
        const typeCount = (type: string) => data.targets.filter(t => t.type === type).length;

        return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';">
    <title>Builder Dashboard</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600;700&family=Outfit:wght@300;400;500;600;700&display=swap');
        
        :root {
            --void: #05070a;
            --abyss: #0a0d12;
            --deep: #0f1419;
            --surface: #151b24;
            --elevated: #1c242f;
            --border: #2a3544;
            --border-subtle: #1e2733;
            
            --text: #e8edf5;
            --text-muted: #8899aa;
            --text-dim: #5a6a7a;
            
            --cyan: #00d4ff;
            --cyan-glow: rgba(0, 212, 255, 0.15);
            --cyan-soft: rgba(0, 212, 255, 0.08);
            
            --emerald: #00ffa3;
            --emerald-glow: rgba(0, 255, 163, 0.15);
            
            --amber: #ffb800;
            --amber-glow: rgba(255, 184, 0, 0.15);
            
            --rose: #ff3366;
            --rose-glow: rgba(255, 51, 102, 0.15);
            
            --violet: #a855f7;
            --violet-glow: rgba(168, 85, 247, 0.15);
            
            --radius: 12px;
            --radius-lg: 16px;
        }
        
        * { box-sizing: border-box; margin: 0; padding: 0; }
        
        body {
            font-family: 'Outfit', -apple-system, BlinkMacSystemFont, sans-serif;
            background: var(--void);
            color: var(--text);
            line-height: 1.5;
            min-height: 100vh;
            overflow-x: hidden;
        }
        
        /* Ambient background */
        .ambient {
            position: fixed;
            inset: 0;
            background: 
                radial-gradient(ellipse 80% 50% at 20% 0%, var(--cyan-soft) 0%, transparent 50%),
                radial-gradient(ellipse 60% 40% at 80% 100%, var(--violet-glow) 0%, transparent 50%);
            pointer-events: none;
            z-index: 0;
        }
        
        .container {
            position: relative;
            z-index: 1;
            max-width: 1100px;
            margin: 0 auto;
            padding: 32px 24px;
        }
        
        /* Header */
        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 40px;
        }
        
        .brand {
            display: flex;
            align-items: center;
            gap: 16px;
        }
        
        .brand-icon {
            width: 48px;
            height: 48px;
            background: linear-gradient(135deg, var(--cyan), var(--emerald));
            border-radius: var(--radius);
            display: grid;
            place-items: center;
            font-size: 24px;
            box-shadow: 0 8px 32px var(--cyan-glow);
        }
        
        .brand h1 {
            font-size: 22px;
            font-weight: 600;
            letter-spacing: -0.02em;
        }
        
        .brand span {
            display: block;
            font-size: 13px;
            color: var(--text-muted);
            font-weight: 400;
            margin-top: 2px;
        }
        
        .header-actions {
            display: flex;
            gap: 10px;
        }
        
        .btn {
            font-family: 'Outfit', sans-serif;
            background: var(--surface);
            border: 1px solid var(--border);
            color: var(--text);
            padding: 10px 18px;
            border-radius: var(--radius);
            cursor: pointer;
            font-size: 13px;
            font-weight: 500;
            display: flex;
            align-items: center;
            gap: 8px;
            transition: all 0.2s ease;
        }
        
        .btn:hover {
            background: var(--elevated);
            border-color: var(--text-dim);
            transform: translateY(-1px);
        }
        
        .btn-glow {
            background: linear-gradient(135deg, var(--cyan), #00b8e6);
            border: none;
            color: var(--void);
            font-weight: 600;
            box-shadow: 0 4px 24px var(--cyan-glow);
        }
        
        .btn-glow:hover {
            filter: brightness(1.1);
            box-shadow: 0 6px 32px var(--cyan-glow);
        }
        
        /* Stats Grid */
        .stats {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 16px;
            margin-bottom: 32px;
        }
        
        .stat-card {
            background: var(--deep);
            border: 1px solid var(--border-subtle);
            border-radius: var(--radius-lg);
            padding: 20px;
            position: relative;
            overflow: hidden;
        }
        
        .stat-card::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            height: 2px;
            background: linear-gradient(90deg, transparent, var(--accent, var(--cyan)), transparent);
            opacity: 0.5;
        }
        
        .stat-card.cyan { --accent: var(--cyan); }
        .stat-card.emerald { --accent: var(--emerald); }
        .stat-card.amber { --accent: var(--amber); }
        .stat-card.violet { --accent: var(--violet); }
        
        .stat-label {
            font-size: 11px;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.1em;
            color: var(--text-dim);
            margin-bottom: 8px;
        }
        
        .stat-value {
            font-family: 'JetBrains Mono', monospace;
            font-size: 28px;
            font-weight: 700;
            color: var(--accent, var(--text));
            line-height: 1;
        }
        
        .stat-sub {
            font-size: 12px;
            color: var(--text-muted);
            margin-top: 6px;
        }
        
        /* Main Grid */
        .main-grid {
            display: grid;
            grid-template-columns: 1fr 320px;
            gap: 24px;
        }
        
        /* Panels */
        .panel {
            background: var(--deep);
            border: 1px solid var(--border-subtle);
            border-radius: var(--radius-lg);
            overflow: hidden;
        }
        
        .panel-header {
            padding: 16px 20px;
            border-bottom: 1px solid var(--border-subtle);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .panel-title {
            font-size: 13px;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.08em;
            color: var(--text-muted);
        }
        
        .panel-body {
            padding: 16px;
        }
        
        /* Targets List */
        .target-item {
            display: flex;
            align-items: center;
            gap: 14px;
            padding: 14px 16px;
            background: var(--surface);
            border-radius: var(--radius);
            margin-bottom: 10px;
            cursor: pointer;
            transition: all 0.2s ease;
            border: 1px solid transparent;
        }
        
        .target-item:hover {
            background: var(--elevated);
            border-color: var(--border);
            transform: translateX(4px);
        }
        
        .target-item:last-child { margin-bottom: 0; }
        
        .target-icon {
            width: 40px;
            height: 40px;
            border-radius: 10px;
            display: grid;
            place-items: center;
            font-size: 18px;
            flex-shrink: 0;
        }
        
        .target-icon.executable {
            background: var(--cyan-glow);
            color: var(--cyan);
            box-shadow: inset 0 0 20px var(--cyan-soft);
        }
        
        .target-icon.library {
            background: var(--violet-glow);
            color: var(--violet);
            box-shadow: inset 0 0 20px rgba(168, 85, 247, 0.08);
        }
        
        .target-icon.test {
            background: var(--emerald-glow);
            color: var(--emerald);
            box-shadow: inset 0 0 20px rgba(0, 255, 163, 0.08);
        }
        
        .target-icon.custom {
            background: var(--amber-glow);
            color: var(--amber);
            box-shadow: inset 0 0 20px rgba(255, 184, 0, 0.08);
        }
        
        .target-info {
            flex: 1;
            min-width: 0;
        }
        
        .target-name {
            font-weight: 600;
            font-size: 14px;
            margin-bottom: 2px;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }
        
        .target-meta {
            font-family: 'JetBrains Mono', monospace;
            font-size: 11px;
            color: var(--text-dim);
        }
        
        .target-action {
            opacity: 0;
            transition: opacity 0.2s;
        }
        
        .target-item:hover .target-action {
            opacity: 1;
        }
        
        /* Quick Actions */
        .actions-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 10px;
        }
        
        .action-btn {
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 10px;
            padding: 20px 16px;
            background: var(--surface);
            border: 1px solid var(--border-subtle);
            border-radius: var(--radius);
            cursor: pointer;
            transition: all 0.2s ease;
            color: var(--text);
        }
        
        .action-btn:hover {
            background: var(--elevated);
            border-color: var(--border);
            transform: translateY(-2px);
        }
        
        .action-icon {
            width: 44px;
            height: 44px;
            border-radius: 12px;
            display: grid;
            place-items: center;
            font-size: 20px;
            background: var(--deep);
            border: 1px solid var(--border-subtle);
        }
        
        .action-btn:hover .action-icon {
            background: var(--surface);
        }
        
        .action-label {
            font-size: 12px;
            font-weight: 500;
            color: var(--text-muted);
        }
        
        /* Cache Meter */
        .cache-meter {
            margin-top: 16px;
        }
        
        .meter-track {
            height: 6px;
            background: var(--surface);
            border-radius: 3px;
            overflow: hidden;
        }
        
        .meter-fill {
            height: 100%;
            background: linear-gradient(90deg, var(--emerald), var(--cyan));
            border-radius: 3px;
            transition: width 0.5s ease;
        }
        
        .meter-label {
            display: flex;
            justify-content: space-between;
            margin-top: 8px;
            font-size: 11px;
            color: var(--text-dim);
        }
        
        /* Empty State */
        .empty-state {
            text-align: center;
            padding: 60px 40px;
        }
        
        .empty-icon {
            width: 80px;
            height: 80px;
            margin: 0 auto 24px;
            background: var(--surface);
            border-radius: 20px;
            display: grid;
            place-items: center;
            font-size: 36px;
            border: 1px dashed var(--border);
        }
        
        .empty-state h3 {
            font-size: 18px;
            font-weight: 600;
            margin-bottom: 8px;
        }
        
        .empty-state p {
            color: var(--text-muted);
            font-size: 14px;
            margin-bottom: 24px;
        }
        
        /* Animations */
        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(10px); }
            to { opacity: 1; transform: translateY(0); }
        }
        
        .stat-card { animation: fadeIn 0.4s ease backwards; }
        .stat-card:nth-child(1) { animation-delay: 0.05s; }
        .stat-card:nth-child(2) { animation-delay: 0.1s; }
        .stat-card:nth-child(3) { animation-delay: 0.15s; }
        .stat-card:nth-child(4) { animation-delay: 0.2s; }
        
        .panel { animation: fadeIn 0.4s ease 0.25s backwards; }
        
        @media (max-width: 900px) {
            .stats { grid-template-columns: repeat(2, 1fr); }
            .main-grid { grid-template-columns: 1fr; }
        }
    </style>
</head>
<body>
    <div class="ambient"></div>
    
    <div class="container">
        <header>
            <div class="brand">
                <div class="brand-icon">⚡</div>
                <div>
                    <h1>${data.projectName}</h1>
                    <span>${data.hasBuilderfile ? `${data.targets.length} targets configured` : 'No Builderfile'}</span>
                </div>
            </div>
            <div class="header-actions">
                <button class="btn" onclick="refresh()">
                    <span>↻</span> Refresh
                </button>
                <button class="btn btn-glow" onclick="build()">
                    <span>▶</span> Build All
                </button>
            </div>
        </header>
        
        ${!data.hasBuilderfile ? `
        <div class="panel">
            <div class="empty-state">
                <div class="empty-icon">📦</div>
                <h3>No Builderfile Found</h3>
                <p>Generate a Builderfile to unlock intelligent builds, caching, and more.</p>
                <button class="btn btn-glow" onclick="generate()">
                    <span>✨</span> Generate Builderfile
                </button>
            </div>
        </div>
        ` : `
        <div class="stats">
            <div class="stat-card cyan">
                <div class="stat-label">Total Targets</div>
                <div class="stat-value">${data.targets.length}</div>
                <div class="stat-sub">Build configurations</div>
            </div>
            <div class="stat-card emerald">
                <div class="stat-label">Executables</div>
                <div class="stat-value">${typeCount('executable')}</div>
                <div class="stat-sub">Runnable outputs</div>
            </div>
            <div class="stat-card violet">
                <div class="stat-label">Cache Size</div>
                <div class="stat-value">${data.cacheStats?.size || '—'}</div>
                <div class="stat-sub">${data.cacheStats?.entries || 0} entries</div>
            </div>
            <div class="stat-card amber">
                <div class="stat-label">Hit Rate</div>
                <div class="stat-value">${data.cacheStats?.hitRate || 0}%</div>
                <div class="stat-sub">Cache efficiency</div>
            </div>
        </div>
        
        <div class="main-grid">
            <div class="panel">
                <div class="panel-header">
                    <span class="panel-title">Build Targets</span>
                </div>
                <div class="panel-body">
                    ${data.targets.map(t => `
                    <div class="target-item" onclick="buildTarget('${t.name}')">
                        <div class="target-icon ${t.type}">
                            ${t.type === 'executable' ? '⚡' : t.type === 'library' ? '📦' : t.type === 'test' ? '🧪' : '⚙️'}
                        </div>
                        <div class="target-info">
                            <div class="target-name">${t.name}</div>
                            <div class="target-meta">${t.language} · ${t.type}</div>
                        </div>
                        <button class="btn target-action">Build</button>
                    </div>
                    `).join('')}
                </div>
            </div>
            
            <div>
                <div class="panel" style="margin-bottom: 16px;">
                    <div class="panel-header">
                        <span class="panel-title">Quick Actions</span>
                    </div>
                    <div class="panel-body">
                        <div class="actions-grid">
                            <button class="action-btn" onclick="build()">
                                <div class="action-icon">▶</div>
                                <span class="action-label">Build</span>
                            </button>
                            <button class="action-btn" onclick="watch()">
                                <div class="action-icon">👁</div>
                                <span class="action-label">Watch</span>
                            </button>
                            <button class="action-btn" onclick="clean()">
                                <div class="action-icon">🗑</div>
                                <span class="action-label">Clean</span>
                            </button>
                            <button class="action-btn" onclick="showGraph()">
                                <div class="action-icon">🔗</div>
                                <span class="action-label">Graph</span>
                            </button>
                        </div>
                    </div>
                </div>
                
                ${data.cacheStats ? `
                <div class="panel">
                    <div class="panel-header">
                        <span class="panel-title">Cache Performance</span>
                    </div>
                    <div class="panel-body">
                        <div class="cache-meter">
                            <div class="meter-track">
                                <div class="meter-fill" style="width: ${data.cacheStats.hitRate}%"></div>
                            </div>
                            <div class="meter-label">
                                <span>${data.cacheStats.hitRate}% hit rate</span>
                                <span>${data.cacheStats.entries} entries</span>
                            </div>
                        </div>
                    </div>
                </div>
                ` : ''}
            </div>
        </div>
        `}
    </div>
    
    <script nonce="${nonce}">
        const vscode = acquireVsCodeApi();
        
        function build() { vscode.postMessage({ command: 'build' }); }
        function buildTarget(target) { vscode.postMessage({ command: 'buildTarget', target }); }
        function clean() { vscode.postMessage({ command: 'clean' }); }
        function watch() { vscode.postMessage({ command: 'watch' }); }
        function showGraph() { vscode.postMessage({ command: 'showGraph' }); }
        function generate() { vscode.postMessage({ command: 'generate' }); }
        function refresh() { vscode.postMessage({ command: 'refresh' }); }
    </script>
</body>
</html>`;
    }
}

interface DashboardData {
    projectName: string;
    hasBuilderfile: boolean;
    targets: TargetInfo[];
    cacheStats: CacheStats | null;
    recentBuilds: BuildInfo[];
}

interface TargetInfo {
    name: string;
    type: string;
    language: string;
}

interface CacheStats {
    size: string;
    entries: number;
    hitRate: number;
}

interface BuildInfo {
    timestamp: string;
    duration: string;
    status: 'success' | 'failed';
    targets: number;
}

function getNonce(): string {
    let text = '';
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    for (let i = 0; i < 32; i++) {
        text += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return text;
}
