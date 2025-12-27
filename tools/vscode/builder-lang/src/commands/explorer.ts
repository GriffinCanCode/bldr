import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';

export function registerExplorerCommands(
    context: vscode.ExtensionContext,
    outputChannel: vscode.OutputChannel
): void {
    // Open target definition
    context.subscriptions.push(
        vscode.commands.registerCommand('builder.openTarget', async (target: { name: string; line?: number }) => {
            await openTargetDefinition(target);
        })
    );
}

async function openTargetDefinition(target: { name: string; line?: number }): Promise<void> {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (!workspaceFolder) return;

    const builderfilePath = path.join(workspaceFolder.uri.fsPath, 'Builderfile');
    if (!fs.existsSync(builderfilePath)) return;

    const doc = await vscode.workspace.openTextDocument(builderfilePath);
    const editor = await vscode.window.showTextDocument(doc);

    // Find target definition in file
    const text = doc.getText();
    const regex = new RegExp(`target\\s*\\(\\s*"${target.name}"\\s*\\)`, 'g');
    const match = regex.exec(text);

    if (match) {
        const position = doc.positionAt(match.index);
        editor.selection = new vscode.Selection(position, position);
        editor.revealRange(new vscode.Range(position, position), vscode.TextEditorRevealType.InCenter);
    } else if (target.line) {
        const position = new vscode.Position(target.line - 1, 0);
        editor.selection = new vscode.Selection(position, position);
        editor.revealRange(new vscode.Range(position, position), vscode.TextEditorRevealType.InCenter);
    }
}

