const vscode = require('vscode');
const path = require('path');
const fs = require('fs');
const { LanguageClient, TransportKind } = require('vscode-languageclient/node');

let client;
let statusBarItem;

/**
 * Activate the Builder Language Server extension
 */
async function activate(context) {
    console.log('Builder Language Server extension activating...');

    // Create status bar button for building (always show, even if LSP isn't available)
    statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
    statusBarItem.command = 'builder.build';
    // Use package icon - represents building blocks
    statusBarItem.text = '$(package) Builder';
    statusBarItem.tooltip = 'Run Builder build';
    statusBarItem.show();
    context.subscriptions.push(statusBarItem);

    // Register the build command
    const buildCommand = vscode.commands.registerCommand('builder.build', async () => {
        await runBuild();
    });
    context.subscriptions.push(buildCommand);

    // Check if LSP is enabled
    const config = vscode.workspace.getConfiguration('builder');
    if (!config.get('lsp.enabled', true)) {
        console.log('Builder LSP is disabled in settings');
        return;
    }

    // Find the builder-lsp executable
    const serverExecutable = findServerExecutable();
    if (!serverExecutable) {
        vscode.window.showWarningMessage(
            'Builder LSP server not found. Install Builder to enable language features.',
            'Install Builder'
        ).then(selection => {
            if (selection === 'Install Builder') {
                vscode.env.openExternal(vscode.Uri.parse('https://github.com/GriffinCanCode/bldr'));
            }
        });
        return;
    }

    console.log('Found Builder LSP server at:', serverExecutable);

    // Configure the language server
    const serverOptions = {
        command: serverExecutable,
        args: [],
        transport: TransportKind.stdio
    };

    // Configure the language client
    const clientOptions = {
        documentSelector: [
            { scheme: 'file', language: 'builder' },
            { scheme: 'file', pattern: '**/Builderfile' },
            { scheme: 'file', pattern: '**/Builderspace' }
        ],
        synchronize: {
            // Notify the server about file changes to Builderfile files
            fileEvents: vscode.workspace.createFileSystemWatcher('**/{Builderfile,Builderspace}')
        },
        diagnosticCollectionName: 'builder',
        outputChannelName: 'Builder LSP',
        traceOutputChannel: vscode.window.createOutputChannel('Builder LSP Trace')
    };

    // Create and start the language client
    client = new LanguageClient(
        'builderLSP',
        'Builder Language Server',
        serverOptions,
        clientOptions
    );

    // Start the client (this will also start the server)
    try {
        await client.start();
        console.log('Builder Language Server started successfully');
        vscode.window.showInformationMessage('Builder Language Server activated');
    } catch (error) {
        console.error('Failed to start Builder Language Server:', error);
        vscode.window.showErrorMessage(`Failed to start Builder LSP: ${error.message}`);
    }
}

/**
 * Run Builder build in the workspace
 */
async function runBuild() {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (!workspaceFolder) {
        vscode.window.showErrorMessage('No workspace folder open');
        return;
    }

    // Find builder executable
    const builderExecutable = findBuilderExecutable();
    if (!builderExecutable) {
        vscode.window.showErrorMessage('Builder executable not found. Please install Builder first.');
        return;
    }

    // Show output channel
    const outputChannel = vscode.window.createOutputChannel('Builder Build');
    outputChannel.clear();
    outputChannel.show(true);
    outputChannel.appendLine('Running Builder build...');
    outputChannel.appendLine('');

    // Update status bar to show building
    if (statusBarItem) {
        statusBarItem.text = '$(sync~spin) Building...';
    }

    try {
        // Run builder command
        const terminal = vscode.window.createTerminal({
            name: 'Builder Build',
            cwd: workspaceFolder.uri.fsPath
        });
        terminal.show();
        terminal.sendText(`${builderExecutable}`);

        if (statusBarItem) {
            statusBarItem.text = '$(tools) Builder';
        }
    } catch (error) {
        outputChannel.appendLine(`Error: ${error.message}`);
        vscode.window.showErrorMessage(`Builder build failed: ${error.message}`);
        if (statusBarItem) {
            statusBarItem.text = '$(tools) Builder';
        }
    }
}

/**
 * Find the builder executable
 */
function findBuilderExecutable() {
    // Check if builder is in PATH
    const pathExecutable = findInPath('builder');
    if (pathExecutable) {
        return pathExecutable;
    }

    // Check common installation locations
    const commonPaths = [
        '/usr/local/bin/builder',
        '/opt/homebrew/bin/builder',
        path.join(process.env.HOME, '.local', 'bin', 'builder')
    ];

    for (const commonPath of commonPaths) {
        if (fs.existsSync(commonPath)) {
            return commonPath;
        }
    }

    return null;
}

/**
 * Deactivate the extension and stop the language server
 */
async function deactivate() {
    if (client) {
        console.log('Stopping Builder Language Server...');
        await client.stop();
    }
    if (statusBarItem) {
        statusBarItem.dispose();
    }
}

/**
 * Find the builder-lsp executable
 * Searches in:
 * 1. Custom path from settings
 * 2. Extension's bin/ directory (platform-specific)
 * 3. System PATH
 * 4. Common installation locations
 */
function findServerExecutable() {
    // Check custom path from settings
    const config = vscode.workspace.getConfiguration('builder');
    const customPath = config.get('lsp.serverPath', '');
    if (customPath && fs.existsSync(customPath)) {
        return customPath;
    }

    // Check extension directory for platform-specific binary
    const platform = process.platform; // 'darwin', 'linux', 'win32'
    const arch = process.arch; // 'arm64', 'x64'
    
    // Try platform-specific binary first
    let binaryName = 'builder-lsp';
    if (platform === 'win32') {
        binaryName += '.exe';
    }
    
    const platformDir = `${platform}-${arch}`;
    const platformPath = path.join(__dirname, 'bin', platformDir, binaryName);
    if (fs.existsSync(platformPath)) {
        // Make sure it's executable on Unix-like systems
        if (platform !== 'win32') {
            try {
                fs.chmodSync(platformPath, 0o755);
            } catch (e) {
                console.warn('Could not set executable permissions:', e);
            }
        }
        return platformPath;
    }
    
    // Fallback to root bin directory (for backward compatibility)
    const extensionPath = path.join(__dirname, 'bin', binaryName);
    if (fs.existsSync(extensionPath)) {
        if (platform !== 'win32') {
            try {
                fs.chmodSync(extensionPath, 0o755);
            } catch (e) {
                console.warn('Could not set executable permissions:', e);
            }
        }
        return extensionPath;
    }

    // Check if builder-lsp is in PATH
    const pathExecutable = findInPath('builder-lsp');
    if (pathExecutable) {
        return pathExecutable;
    }

    // Check common installation locations
    const commonPaths = [
        '/usr/local/bin/builder-lsp',
        '/opt/homebrew/bin/builder-lsp',
        path.join(process.env.HOME, '.local', 'bin', 'builder-lsp')
    ];

    for (const commonPath of commonPaths) {
        if (fs.existsSync(commonPath)) {
            return commonPath;
        }
    }

    return null;
}

/**
 * Find executable in system PATH
 */
function findInPath(executable) {
    const pathEnv = process.env.PATH || '';
    const pathDirs = pathEnv.split(path.delimiter);

    for (const dir of pathDirs) {
        const fullPath = path.join(dir, executable);
        if (fs.existsSync(fullPath)) {
            try {
                fs.accessSync(fullPath, fs.constants.X_OK);
                return fullPath;
            } catch (e) {
                // Not executable, continue searching
            }
        }
    }

    return null;
}

module.exports = {
    activate,
    deactivate
};

