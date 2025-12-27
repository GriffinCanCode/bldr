import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';

interface GraphNode {
    id: string;
    label: string;
    type: string;
    language: string;
}

interface GraphEdge {
    source: string;
    target: string;
}

interface GraphData {
    nodes: GraphNode[];
    edges: GraphEdge[];
}

export class GraphPanel {
    public static currentPanel: GraphPanel | undefined;
    private readonly _panel: vscode.WebviewPanel;
    private readonly _extensionUri: vscode.Uri;
    private _disposables: vscode.Disposable[] = [];

    public static createOrShow(extensionUri: vscode.Uri): void {
        const column = vscode.ViewColumn.Beside;

        if (GraphPanel.currentPanel) {
            GraphPanel.currentPanel._panel.reveal(column);
            GraphPanel.currentPanel._update();
            return;
        }

        const panel = vscode.window.createWebviewPanel(
            'builderGraph',
            'Dependency Graph',
            column,
            { enableScripts: true, retainContextWhenHidden: true }
        );

        GraphPanel.currentPanel = new GraphPanel(panel, extensionUri);
    }

    private constructor(panel: vscode.WebviewPanel, extensionUri: vscode.Uri) {
        this._panel = panel;
        this._extensionUri = extensionUri;
        this._update();

        this._panel.onDidDispose(() => this.dispose(), null, this._disposables);

        this._panel.webview.onDidReceiveMessage(
            async (message) => {
                switch (message.command) {
                    case 'selectNode':
                        vscode.commands.executeCommand('builder.openTarget', { name: message.nodeId });
                        break;
                    case 'buildNode':
                        vscode.commands.executeCommand('builder.buildTarget', message.nodeId);
                        break;
                    case 'refresh':
                        this._update();
                        break;
                }
            },
            null,
            this._disposables
        );

        const watcher = vscode.workspace.createFileSystemWatcher('**/{Builderfile,Builderspace}');
        watcher.onDidChange(() => this._update());
        this._disposables.push(watcher);
    }

    public dispose(): void {
        GraphPanel.currentPanel = undefined;
        this._panel.dispose();
        while (this._disposables.length) {
            this._disposables.pop()?.dispose();
        }
    }

    private async _update(): Promise<void> {
        const data = await this._buildGraphData();
        this._panel.webview.html = this._getHtml(data);
    }

    private async _buildGraphData(): Promise<GraphData> {
        const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
        if (!workspaceFolder) return { nodes: [], edges: [] };

        const builderfilePath = path.join(workspaceFolder.uri.fsPath, 'Builderfile');
        if (!fs.existsSync(builderfilePath)) return { nodes: [], edges: [] };

        const content = fs.readFileSync(builderfilePath, 'utf-8');
        const nodes: GraphNode[] = [];
        const edges: GraphEdge[] = [];

        const targetRegex = /target\s*\(\s*"([^"]+)"\s*\)\s*\{([^}]+)\}/g;
        let match;

        while ((match = targetRegex.exec(content)) !== null) {
            const name = match[1];
            const body = match[2];

            const typeMatch = body.match(/type\s*:\s*(\w+)/);
            const langMatch = body.match(/language\s*:\s*(\w+)/);
            const depsMatch = body.match(/deps\s*:\s*\[([^\]]+)\]/);

            nodes.push({
                id: name,
                label: name,
                type: typeMatch?.[1] || 'unknown',
                language: langMatch?.[1] || 'unknown'
            });

            if (depsMatch) {
                const deps = depsMatch[1].split(',')
                    .map(d => d.trim().replace(/[":]/g, '').replace(/^:/, ''))
                    .filter(Boolean);
                
                for (const dep of deps) {
                    edges.push({ source: dep, target: name });
                }
            }
        }

        return { nodes, edges };
    }

    private _getHtml(data: GraphData): string {
        const nonce = getNonce();
        const nodesJson = JSON.stringify(data.nodes);
        const edgesJson = JSON.stringify(data.edges);

        return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';">
    <title>Dependency Graph</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500&family=Outfit:wght@400;500;600&display=swap');
        
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
            --cyan-glow: rgba(0, 212, 255, 0.25);
            --emerald: #00ffa3;
            --emerald-glow: rgba(0, 255, 163, 0.25);
            --amber: #ffb800;
            --amber-glow: rgba(255, 184, 0, 0.25);
            --violet: #a855f7;
            --violet-glow: rgba(168, 85, 247, 0.25);
            --rose: #ff3366;
        }
        
        * { box-sizing: border-box; margin: 0; padding: 0; }
        
        body {
            font-family: 'Outfit', sans-serif;
            background: var(--void);
            color: var(--text);
            overflow: hidden;
            height: 100vh;
        }
        
        .ambient {
            position: fixed;
            inset: 0;
            background: 
                radial-gradient(ellipse 60% 40% at 30% 20%, rgba(0, 212, 255, 0.05) 0%, transparent 50%),
                radial-gradient(ellipse 50% 30% at 70% 80%, rgba(168, 85, 247, 0.05) 0%, transparent 50%);
            pointer-events: none;
        }
        
        .container {
            display: flex;
            flex-direction: column;
            height: 100vh;
            position: relative;
            z-index: 1;
        }
        
        .toolbar {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 14px 20px;
            background: var(--deep);
            border-bottom: 1px solid var(--border-subtle);
        }
        
        .toolbar-left {
            display: flex;
            align-items: center;
            gap: 12px;
        }
        
        .toolbar-icon {
            width: 32px;
            height: 32px;
            background: linear-gradient(135deg, var(--cyan), var(--violet));
            border-radius: 8px;
            display: grid;
            place-items: center;
            font-size: 16px;
        }
        
        .toolbar h2 {
            font-size: 14px;
            font-weight: 600;
        }
        
        .toolbar-actions {
            display: flex;
            gap: 8px;
        }
        
        .btn {
            font-family: 'Outfit', sans-serif;
            background: var(--surface);
            border: 1px solid var(--border-subtle);
            color: var(--text-muted);
            padding: 8px 14px;
            border-radius: 8px;
            cursor: pointer;
            font-size: 12px;
            font-weight: 500;
            display: flex;
            align-items: center;
            gap: 6px;
            transition: all 0.15s ease;
        }
        
        .btn:hover {
            background: var(--elevated);
            color: var(--text);
            border-color: var(--border);
        }
        
        .canvas-container {
            flex: 1;
            position: relative;
            overflow: hidden;
        }
        
        #graph {
            width: 100%;
            height: 100%;
        }
        
        .node {
            cursor: pointer;
            transition: transform 0.15s ease, filter 0.15s ease;
        }
        
        .node:hover {
            transform: scale(1.08);
            filter: brightness(1.1);
        }
        
        .node-body {
            fill: var(--deep);
            stroke-width: 2;
            rx: 12;
            ry: 12;
        }
        
        .node-executable .node-body { stroke: var(--cyan); }
        .node-library .node-body { stroke: var(--violet); }
        .node-test .node-body { stroke: var(--emerald); }
        .node-custom .node-body { stroke: var(--amber); }
        
        .node-glow {
            fill: none;
            stroke-width: 1;
            opacity: 0.4;
            rx: 14;
            ry: 14;
        }
        
        .node-executable .node-glow { stroke: var(--cyan); filter: blur(8px); }
        .node-library .node-glow { stroke: var(--violet); filter: blur(8px); }
        .node-test .node-glow { stroke: var(--emerald); filter: blur(8px); }
        .node-custom .node-glow { stroke: var(--amber); filter: blur(8px); }
        
        .node-icon {
            font-size: 18px;
            text-anchor: middle;
            dominant-baseline: middle;
        }
        
        .node-label {
            font-family: 'Outfit', sans-serif;
            font-size: 12px;
            font-weight: 600;
            fill: var(--text);
            text-anchor: middle;
        }
        
        .node-meta {
            font-family: 'JetBrains Mono', monospace;
            font-size: 10px;
            fill: var(--text-dim);
            text-anchor: middle;
        }
        
        .edge {
            stroke: var(--border);
            stroke-width: 2;
            fill: none;
            opacity: 0.6;
        }
        
        .edge-arrow {
            fill: var(--border);
            opacity: 0.6;
        }
        
        .legend {
            position: absolute;
            bottom: 20px;
            right: 20px;
            background: var(--deep);
            border: 1px solid var(--border-subtle);
            border-radius: 12px;
            padding: 16px;
            min-width: 140px;
        }
        
        .legend-title {
            font-size: 10px;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.1em;
            color: var(--text-dim);
            margin-bottom: 12px;
        }
        
        .legend-item {
            display: flex;
            align-items: center;
            gap: 10px;
            font-size: 12px;
            color: var(--text-muted);
            margin-bottom: 8px;
        }
        
        .legend-item:last-child { margin-bottom: 0; }
        
        .legend-dot {
            width: 10px;
            height: 10px;
            border-radius: 50%;
        }
        
        .legend-dot.executable { background: var(--cyan); box-shadow: 0 0 8px var(--cyan-glow); }
        .legend-dot.library { background: var(--violet); box-shadow: 0 0 8px var(--violet-glow); }
        .legend-dot.test { background: var(--emerald); box-shadow: 0 0 8px var(--emerald-glow); }
        .legend-dot.custom { background: var(--amber); box-shadow: 0 0 8px var(--amber-glow); }
        
        .empty-state {
            position: absolute;
            inset: 0;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            color: var(--text-dim);
        }
        
        .empty-icon {
            width: 72px;
            height: 72px;
            background: var(--surface);
            border: 1px dashed var(--border);
            border-radius: 16px;
            display: grid;
            place-items: center;
            font-size: 32px;
            margin-bottom: 20px;
        }
        
        .empty-state h3 {
            font-size: 16px;
            font-weight: 600;
            color: var(--text);
            margin-bottom: 6px;
        }
        
        .controls {
            position: absolute;
            bottom: 20px;
            left: 20px;
            display: flex;
            gap: 6px;
        }
        
        .control-btn {
            width: 36px;
            height: 36px;
            background: var(--deep);
            border: 1px solid var(--border-subtle);
            border-radius: 8px;
            color: var(--text-muted);
            cursor: pointer;
            display: grid;
            place-items: center;
            font-size: 14px;
            transition: all 0.15s ease;
        }
        
        .control-btn:hover {
            background: var(--surface);
            color: var(--text);
            border-color: var(--border);
        }
        
        @keyframes pulse {
            0%, 100% { opacity: 0.4; }
            50% { opacity: 0.7; }
        }
        
        .node-glow { animation: pulse 3s ease-in-out infinite; }
    </style>
</head>
<body>
    <div class="ambient"></div>
    
    <div class="container">
        <div class="toolbar">
            <div class="toolbar-left">
                <div class="toolbar-icon">🔗</div>
                <h2>Dependency Graph</h2>
            </div>
            <div class="toolbar-actions">
                <button class="btn" onclick="zoomIn()">+ Zoom</button>
                <button class="btn" onclick="zoomOut()">- Zoom</button>
                <button class="btn" onclick="resetView()">⟲ Reset</button>
                <button class="btn" onclick="refresh()">↻ Refresh</button>
            </div>
        </div>
        
        <div class="canvas-container">
            ${data.nodes.length === 0 ? `
            <div class="empty-state">
                <div class="empty-icon">🔗</div>
                <h3>No Dependencies</h3>
                <p>Add targets to your Builderfile to visualize dependencies</p>
            </div>
            ` : `
            <svg id="graph"></svg>
            
            <div class="controls">
                <button class="control-btn" onclick="zoomIn()">+</button>
                <button class="control-btn" onclick="zoomOut()">−</button>
                <button class="control-btn" onclick="resetView()">⌂</button>
            </div>
            
            <div class="legend">
                <div class="legend-title">Target Types</div>
                <div class="legend-item">
                    <div class="legend-dot executable"></div>
                    <span>Executable</span>
                </div>
                <div class="legend-item">
                    <div class="legend-dot library"></div>
                    <span>Library</span>
                </div>
                <div class="legend-item">
                    <div class="legend-dot test"></div>
                    <span>Test</span>
                </div>
                <div class="legend-item">
                    <div class="legend-dot custom"></div>
                    <span>Custom</span>
                </div>
            </div>
            `}
        </div>
    </div>
    
    <script nonce="${nonce}">
        const vscode = acquireVsCodeApi();
        const nodes = ${nodesJson};
        const edges = ${edgesJson};
        
        let scale = 1;
        const NODE_WIDTH = 140;
        const NODE_HEIGHT = 70;
        
        function refresh() { vscode.postMessage({ command: 'refresh' }); }
        function zoomIn() { scale = Math.min(scale * 1.25, 3); renderGraph(); }
        function zoomOut() { scale = Math.max(scale / 1.25, 0.4); renderGraph(); }
        function resetView() { scale = 1; renderGraph(); }
        
        function renderGraph() {
            if (nodes.length === 0) return;
            
            const svg = document.getElementById('graph');
            const width = svg.clientWidth;
            const height = svg.clientHeight;
            
            const levels = calculateLevels();
            const positions = calculatePositions(levels, width, height);
            
            const icons = { executable: '⚡', library: '📦', test: '🧪', custom: '⚙️' };
            
            let html = '<defs>' +
                '<marker id="arrow" markerWidth="12" markerHeight="8" refX="10" refY="4" orient="auto">' +
                '<path d="M0,0 L12,4 L0,8 L3,4 Z" class="edge-arrow"/>' +
                '</marker>' +
                '</defs>';
            
            // Draw edges
            html += '<g class="edges">';
            for (const edge of edges) {
                const src = positions[edge.source];
                const tgt = positions[edge.target];
                if (src && tgt) {
                    const dy = tgt.y - src.y - NODE_HEIGHT;
                    const ctrl = dy / 2;
                    html += '<path class="edge" marker-end="url(#arrow)" d="' +
                        'M' + src.x + ',' + (src.y + NODE_HEIGHT/2) + ' ' +
                        'C' + src.x + ',' + (src.y + NODE_HEIGHT/2 + ctrl) + ' ' +
                        tgt.x + ',' + (tgt.y - NODE_HEIGHT/2 - ctrl) + ' ' +
                        tgt.x + ',' + (tgt.y - NODE_HEIGHT/2 - 10) + '"/>';
                }
            }
            html += '</g>';
            
            // Draw nodes
            html += '<g class="nodes">';
            for (const node of nodes) {
                const pos = positions[node.id];
                if (!pos) continue;
                
                const x = pos.x - NODE_WIDTH/2;
                const y = pos.y - NODE_HEIGHT/2;
                const icon = icons[node.type] || '⚙️';
                
                html += '<g class="node node-' + node.type + '" ' +
                    'transform="translate(' + x + ',' + y + ')" ' +
                    'onclick="selectNode(\\'' + node.id + '\\')" ' +
                    'ondblclick="buildNode(\\'' + node.id + '\\')">' +
                    '<rect class="node-glow" x="-2" y="-2" width="' + (NODE_WIDTH+4) + '" height="' + (NODE_HEIGHT+4) + '"/>' +
                    '<rect class="node-body" x="0" y="0" width="' + NODE_WIDTH + '" height="' + NODE_HEIGHT + '"/>' +
                    '<text class="node-icon" x="' + NODE_WIDTH/2 + '" y="24">' + icon + '</text>' +
                    '<text class="node-label" x="' + NODE_WIDTH/2 + '" y="45">' + node.label + '</text>' +
                    '<text class="node-meta" x="' + NODE_WIDTH/2 + '" y="60">' + node.language + '</text>' +
                    '</g>';
            }
            html += '</g>';
            
            svg.innerHTML = html;
        }
        
        function selectNode(id) { vscode.postMessage({ command: 'selectNode', nodeId: id }); }
        function buildNode(id) { vscode.postMessage({ command: 'buildNode', nodeId: id }); }
        
        function calculateLevels() {
            const levels = {};
            const incoming = {};
            
            for (const node of nodes) incoming[node.id] = 0;
            for (const edge of edges) incoming[edge.target] = (incoming[edge.target] || 0) + 1;
            
            const queue = nodes.filter(n => incoming[n.id] === 0).map(n => n.id);
            let level = 0;
            
            while (queue.length > 0) {
                const nextQueue = [];
                for (const nodeId of queue) {
                    levels[nodeId] = level;
                    for (const edge of edges) {
                        if (edge.source === nodeId) {
                            incoming[edge.target]--;
                            if (incoming[edge.target] === 0) nextQueue.push(edge.target);
                        }
                    }
                }
                queue.length = 0;
                queue.push(...nextQueue);
                level++;
            }
            
            for (const node of nodes) {
                if (levels[node.id] === undefined) levels[node.id] = level;
            }
            
            return levels;
        }
        
        function calculatePositions(levels, width, height) {
            const positions = {};
            const maxLevel = Math.max(...Object.values(levels), 0);
            const levelHeight = height / (maxLevel + 2);
            
            const byLevel = {};
            for (const [nodeId, level] of Object.entries(levels)) {
                if (!byLevel[level]) byLevel[level] = [];
                byLevel[level].push(nodeId);
            }
            
            for (const [level, nodeIds] of Object.entries(byLevel)) {
                const y = (parseInt(level) + 1) * levelHeight;
                const spacing = width / (nodeIds.length + 1);
                nodeIds.forEach((nodeId, i) => {
                    positions[nodeId] = { x: (i + 1) * spacing, y };
                });
            }
            
            return positions;
        }
        
        if (nodes.length > 0) {
            requestAnimationFrame(() => renderGraph());
            window.addEventListener('resize', () => renderGraph());
        }
    </script>
</body>
</html>`;
    }
}

function getNonce(): string {
    let text = '';
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    for (let i = 0; i < 32; i++) {
        text += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return text;
}
