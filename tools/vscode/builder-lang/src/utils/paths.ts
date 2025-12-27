import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';

/**
 * Find an executable in system PATH or common locations
 */
export function findExecutable(name: string): string | undefined {
    // Check custom setting first
    const config = vscode.workspace.getConfiguration('builder');
    const customPath = config.get<string>('cli.path');
    if (customPath && fs.existsSync(customPath)) {
        return customPath;
    }

    // Check PATH
    const pathResult = findInPath(name);
    if (pathResult) return pathResult;

    // Check common locations
    const commonPaths = [
        `/usr/local/bin/${name}`,
        `/opt/homebrew/bin/${name}`,
        path.join(process.env.HOME || '', '.local', 'bin', name),
        path.join(process.env.HOME || '', '.cargo', 'bin', name)
    ];

    for (const p of commonPaths) {
        if (fs.existsSync(p)) return p;
    }

    return undefined;
}

/**
 * Find the LSP server executable
 */
export function findLspServer(context: vscode.ExtensionContext): string | undefined {
    // Check custom setting
    const config = vscode.workspace.getConfiguration('builder');
    const customPath = config.get<string>('lsp.serverPath');
    if (customPath && fs.existsSync(customPath)) {
        return customPath;
    }

    // Check extension bundled binary
    const platform = process.platform;
    const arch = process.arch;
    const binaryName = platform === 'win32' ? 'builder-lsp.exe' : 'builder-lsp';
    
    const platformDir = `${platform}-${arch}`;
    const bundledPath = path.join(context.extensionPath, 'bin', platformDir, binaryName);
    if (fs.existsSync(bundledPath)) {
        makeExecutable(bundledPath);
        return bundledPath;
    }

    // Fallback to root bin
    const rootBundled = path.join(context.extensionPath, 'bin', binaryName);
    if (fs.existsSync(rootBundled)) {
        makeExecutable(rootBundled);
        return rootBundled;
    }

    // Check PATH
    const pathResult = findInPath('builder-lsp');
    if (pathResult) return pathResult;

    // Check bldr-lsp alias
    const aliasResult = findInPath('bldr-lsp');
    if (aliasResult) return aliasResult;

    // Check common locations
    const commonPaths = [
        '/usr/local/bin/builder-lsp',
        '/opt/homebrew/bin/builder-lsp',
        '/opt/homebrew/bin/bldr-lsp',
        path.join(process.env.HOME || '', '.local', 'bin', 'builder-lsp')
    ];

    for (const p of commonPaths) {
        if (fs.existsSync(p)) return p;
    }

    return undefined;
}

function findInPath(executable: string): string | undefined {
    const pathEnv = process.env.PATH || '';
    const pathDirs = pathEnv.split(path.delimiter);

    for (const dir of pathDirs) {
        const fullPath = path.join(dir, executable);
        if (fs.existsSync(fullPath)) {
            try {
                fs.accessSync(fullPath, fs.constants.X_OK);
                return fullPath;
            } catch {
                // Not executable, continue
            }
        }
    }

    return undefined;
}

function makeExecutable(filePath: string): void {
    if (process.platform !== 'win32') {
        try {
            fs.chmodSync(filePath, 0o755);
        } catch {
            // Ignore permission errors
        }
    }
}

