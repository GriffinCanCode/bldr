import * as vscode from 'vscode';
import { LanguageClient, TransportKind } from 'vscode-languageclient/node';
import { BuilderTargetsProvider } from './providers/targetsProvider';
import { QuickActionsProvider } from './providers/actionsProvider';
import { CacheStatusProvider } from './providers/cacheProvider';
import { DashboardPanel } from './webview/dashboard';
import { GraphPanel } from './webview/graphPanel';
import { registerBuildCommands } from './commands/build';
import { registerGeneratorCommands } from './commands/generator';
import { registerExplorerCommands } from './commands/explorer';
import { findExecutable, findLspServer } from './utils/paths';
import { ProjectAnalyzer } from './utils/analyzer';

let client: LanguageClient | undefined;
let statusBarItem: vscode.StatusBarItem;
let outputChannel: vscode.OutputChannel;
let targetsProvider: BuilderTargetsProvider;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
    outputChannel = vscode.window.createOutputChannel('Builder');
    outputChannel.appendLine('Builder IDE Extension activating...');

    // Create status bar
    statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
    statusBarItem.command = 'builder.showDashboard';
    statusBarItem.text = '$(package) Builder';
    statusBarItem.tooltip = 'Open Builder Dashboard';
    statusBarItem.show();
    context.subscriptions.push(statusBarItem);

    // Initialize providers
    targetsProvider = new BuilderTargetsProvider(context);
    const actionsProvider = new QuickActionsProvider();
    const cacheProvider = new CacheStatusProvider();

    // Register tree views
    context.subscriptions.push(
        vscode.window.registerTreeDataProvider('builder.targets', targetsProvider),
        vscode.window.registerTreeDataProvider('builder.quickActions', actionsProvider),
        vscode.window.registerTreeDataProvider('builder.cacheInfo', cacheProvider)
    );

    // Register all commands
    registerBuildCommands(context, outputChannel, statusBarItem);
    registerGeneratorCommands(context, outputChannel, targetsProvider);
    registerExplorerCommands(context, outputChannel);

    // Dashboard command
    context.subscriptions.push(
        vscode.commands.registerCommand('builder.showDashboard', () => {
            DashboardPanel.createOrShow(context.extensionUri);
        })
    );

    // Graph visualizer command
    context.subscriptions.push(
        vscode.commands.registerCommand('builder.showGraph', () => {
            GraphPanel.createOrShow(context.extensionUri);
        })
    );

    // Refresh explorer command
    context.subscriptions.push(
        vscode.commands.registerCommand('builder.refreshExplorer', () => {
            targetsProvider.refresh();
            cacheProvider.refresh();
        })
    );

    // Auto-detect on workspace open if no Builderfile
    const config = vscode.workspace.getConfiguration('builder');
    if (config.get('autoDetect.enabled', true)) {
        await checkAutoDetection(context);
    }

    // Start LSP if enabled
    if (config.get('lsp.enabled', true)) {
        await startLanguageServer(context);
    }

    // Watch for Builderfile changes
    const watcher = vscode.workspace.createFileSystemWatcher('**/{Builderfile,Builderspace}');
    watcher.onDidChange(() => targetsProvider.refresh());
    watcher.onDidCreate(() => targetsProvider.refresh());
    watcher.onDidDelete(() => targetsProvider.refresh());
    context.subscriptions.push(watcher);

    outputChannel.appendLine('Builder IDE Extension activated successfully');
}

async function startLanguageServer(context: vscode.ExtensionContext): Promise<void> {
    const serverPath = findLspServer(context);
    if (!serverPath) {
        const action = await vscode.window.showWarningMessage(
            'Builder LSP server not found. Install Builder to enable intelligent features.',
            'Install Builder',
            'Configure Path'
        );
        if (action === 'Install Builder') {
            vscode.env.openExternal(vscode.Uri.parse('https://github.com/GriffinCanCode/bldr'));
        } else if (action === 'Configure Path') {
            vscode.commands.executeCommand('workbench.action.openSettings', 'builder.lsp.serverPath');
        }
        return;
    }

    outputChannel.appendLine(`Found LSP server at: ${serverPath}`);

    const serverOptions = {
        command: serverPath,
        args: [],
        transport: TransportKind.stdio
    };

    const clientOptions = {
        documentSelector: [
            { scheme: 'file', language: 'builder' },
            { scheme: 'file', pattern: '**/Builderfile' },
            { scheme: 'file', pattern: '**/Builderspace' }
        ],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/{Builderfile,Builderspace}')
        },
        diagnosticCollectionName: 'builder',
        outputChannel
    };

    client = new LanguageClient('builderLSP', 'Builder Language Server', serverOptions, clientOptions);

    try {
        await client.start();
        outputChannel.appendLine('Builder Language Server started successfully');
    } catch (error) {
        outputChannel.appendLine(`Failed to start LSP: ${error}`);
        vscode.window.showErrorMessage(`Builder LSP failed: ${error}`);
    }
}

async function checkAutoDetection(context: vscode.ExtensionContext): Promise<void> {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (!workspaceFolder) return;

    const builderfile = vscode.Uri.joinPath(workspaceFolder.uri, 'Builderfile');
    try {
        await vscode.workspace.fs.stat(builderfile);
        // Builderfile exists, no need for auto-detection prompt
    } catch {
        // No Builderfile, check if we should suggest generation
        const analyzer = new ProjectAnalyzer(workspaceFolder.uri.fsPath);
        const detected = await analyzer.quickScan();
        
        if (detected.languages.length > 0) {
            const config = vscode.workspace.getConfiguration('builder');
            if (config.get('autoDetect.showNotification', true)) {
                const action = await vscode.window.showInformationMessage(
                    `Builder detected ${detected.languages.join(', ')} project. Generate Builderfile?`,
                    'Generate',
                    'Preview',
                    'Dismiss'
                );
                if (action === 'Generate') {
                    vscode.commands.executeCommand('builder.generateBuilderfile');
                } else if (action === 'Preview') {
                    vscode.commands.executeCommand('builder.previewTargets');
                }
            }
        }
    }
}

export async function deactivate(): Promise<void> {
    if (client) {
        await client.stop();
    }
    statusBarItem?.dispose();
}

