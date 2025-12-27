import * as vscode from 'vscode';

interface QuickAction {
    label: string;
    command: string;
    icon: string;
    description: string;
}

export class QuickActionsProvider implements vscode.TreeDataProvider<ActionTreeItem> {
    private _onDidChangeTreeData = new vscode.EventEmitter<ActionTreeItem | undefined>();
    readonly onDidChangeTreeData = this._onDidChangeTreeData.event;

    private readonly actions: QuickAction[] = [
        { label: 'Build All', command: 'builder.build', icon: 'play', description: 'Build all targets' },
        { label: 'Run Tests', command: 'builder.test', icon: 'beaker', description: 'Execute test targets' },
        { label: 'Watch Mode', command: 'builder.watch', icon: 'eye', description: 'Rebuild on changes' },
        { label: 'Clean', command: 'builder.clean', icon: 'trash', description: 'Remove artifacts' },
        { label: 'View Graph', command: 'builder.showGraph', icon: 'type-hierarchy', description: 'Dependency visualization' },
        { label: 'Analytics', command: 'builder.telemetry', icon: 'graph', description: 'Build performance' },
        { label: 'Generate File', command: 'builder.generateBuilderfile', icon: 'sparkle', description: 'Auto-generate Builderfile' }
    ];

    refresh(): void {
        this._onDidChangeTreeData.fire(undefined);
    }

    getTreeItem(element: ActionTreeItem): vscode.TreeItem {
        return element;
    }

    getChildren(): Thenable<ActionTreeItem[]> {
        return Promise.resolve(
            this.actions.map(action => {
                const item = new ActionTreeItem(action.label, vscode.TreeItemCollapsibleState.None);
                item.iconPath = new vscode.ThemeIcon(action.icon);
                item.description = action.description;
                item.command = { command: action.command, title: action.label };
                return item;
            })
        );
    }
}

class ActionTreeItem extends vscode.TreeItem {
    constructor(label: string, collapsibleState: vscode.TreeItemCollapsibleState) {
        super(label, collapsibleState);
    }
}

