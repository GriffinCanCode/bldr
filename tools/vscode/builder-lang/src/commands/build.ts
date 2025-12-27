import * as vscode from 'vscode';
import { findExecutable } from '../utils/paths';

export function registerBuildCommands(
    context: vscode.ExtensionContext,
    outputChannel: vscode.OutputChannel,
    statusBarItem: vscode.StatusBarItem
): void {
    // Build all targets
    context.subscriptions.push(
        vscode.commands.registerCommand('builder.build', async () => {
            await runBuild(undefined, outputChannel, statusBarItem);
        })
    );

    // Build specific target
    context.subscriptions.push(
        vscode.commands.registerCommand('builder.buildTarget', async (target?: string) => {
            if (!target) {
                target = await promptForTarget();
            }
            if (target) {
                await runBuild(target, outputChannel, statusBarItem);
            }
        })
    );

    // Run tests
    context.subscriptions.push(
        vscode.commands.registerCommand('builder.test', async () => {
            await runCommand('test', [], outputChannel, statusBarItem);
        })
    );

    // Watch mode
    context.subscriptions.push(
        vscode.commands.registerCommand('builder.watch', async () => {
            const config = vscode.workspace.getConfiguration('builder');
            const args = config.get('watch.clearOnRebuild', false) ? ['--clear'] : [];
            await runCommand('watch', args, outputChannel, statusBarItem, true);
        })
    );

    // Clean
    context.subscriptions.push(
        vscode.commands.registerCommand('builder.clean', async () => {
            await runCommand('clean', [], outputChannel, statusBarItem);
        })
    );

    // Query
    context.subscriptions.push(
        vscode.commands.registerCommand('builder.query', async () => {
            const query = await vscode.window.showInputBox({
                prompt: 'Enter query expression',
                placeHolder: 'e.g., deps(:main), rdeps(:lib), //...'
            });
            if (query) {
                await runCommand('query', [query], outputChannel, statusBarItem);
            }
        })
    );

    // Telemetry/Analytics
    context.subscriptions.push(
        vscode.commands.registerCommand('builder.telemetry', async () => {
            await runCommand('telemetry', [], outputChannel, statusBarItem);
        })
    );

    // Cache stats
    context.subscriptions.push(
        vscode.commands.registerCommand('builder.cacheStats', async () => {
            await runCommand('cache', ['stats'], outputChannel, statusBarItem);
        })
    );

    // Interactive explorer
    context.subscriptions.push(
        vscode.commands.registerCommand('builder.explore', async () => {
            // Open in integrated terminal for TUI
            const terminal = vscode.window.createTerminal({
                name: 'Builder Explorer',
                cwd: vscode.workspace.workspaceFolders?.[0]?.uri.fsPath
            });
            terminal.show();
            const cli = findExecutable('bldr') || 'bldr';
            terminal.sendText(`${cli} explore`);
        })
    );
}

async function runBuild(
    target: string | undefined,
    outputChannel: vscode.OutputChannel,
    statusBarItem: vscode.StatusBarItem
): Promise<void> {
    const config = vscode.workspace.getConfiguration('builder');
    const args: string[] = [];

    if (target) args.push(target);
    if (config.get('build.verbose', false)) args.push('--verbose');
    if (!config.get('build.parallel', true)) args.push('--no-parallel');

    await runCommand('build', args, outputChannel, statusBarItem);
}

async function runCommand(
    command: string,
    args: string[],
    outputChannel: vscode.OutputChannel,
    statusBarItem: vscode.StatusBarItem,
    keepRunning = false
): Promise<void> {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (!workspaceFolder) {
        vscode.window.showErrorMessage('No workspace folder open');
        return;
    }

    const cli = findExecutable('bldr');
    if (!cli) {
        vscode.window.showErrorMessage('Builder CLI (bldr) not found. Please install Builder.');
        return;
    }

    outputChannel.clear();
    outputChannel.show(true);
    outputChannel.appendLine(`Running: bldr ${command} ${args.join(' ')}`);
    outputChannel.appendLine('');

    const originalText = statusBarItem.text;
    statusBarItem.text = '$(sync~spin) Building...';

    const terminal = vscode.window.createTerminal({
        name: `Builder: ${command}`,
        cwd: workspaceFolder.uri.fsPath,
        isTransient: !keepRunning
    });
    terminal.show();
    terminal.sendText(`${cli} ${command} ${args.join(' ')}`);

    // Restore status bar after a delay (since we can't easily track terminal completion)
    if (!keepRunning) {
        setTimeout(() => {
            statusBarItem.text = originalText;
        }, 2000);
    }
}

async function promptForTarget(): Promise<string | undefined> {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (!workspaceFolder) return undefined;

    // Try to get targets from Builderfile
    const targets = await getAvailableTargets(workspaceFolder.uri.fsPath);
    if (targets.length === 0) {
        return vscode.window.showInputBox({
            prompt: 'Enter target name',
            placeHolder: 'e.g., main, lib, test'
        });
    }

    const items = targets.map(t => ({
        label: t.name,
        description: `${t.type} • ${t.language}`,
        target: t.name
    }));

    const selected = await vscode.window.showQuickPick(items, {
        placeHolder: 'Select target to build'
    });

    return selected?.target;
}

interface TargetInfo {
    name: string;
    type: string;
    language: string;
}

async function getAvailableTargets(workspaceDir: string): Promise<TargetInfo[]> {
    const fs = await import('fs');
    const path = await import('path');
    
    const builderfilePath = path.join(workspaceDir, 'Builderfile');
    if (!fs.existsSync(builderfilePath)) return [];

    try {
        const content = fs.readFileSync(builderfilePath, 'utf-8');
        const targets: TargetInfo[] = [];
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

        return targets;
    } catch {
        return [];
    }
}

