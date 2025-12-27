import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';
import { ProjectAnalyzer, DetectedProject, DetectedTarget } from '../utils/analyzer';
import { BuilderTargetsProvider } from '../providers/targetsProvider';
import { findExecutable } from '../utils/paths';

export function registerGeneratorCommands(
    context: vscode.ExtensionContext,
    outputChannel: vscode.OutputChannel,
    targetsProvider: BuilderTargetsProvider
): void {
    // Generate Builderfile from project analysis
    context.subscriptions.push(
        vscode.commands.registerCommand('builder.generateBuilderfile', async () => {
            await generateBuilderfile(outputChannel, targetsProvider);
        })
    );

    // Preview auto-detected targets
    context.subscriptions.push(
        vscode.commands.registerCommand('builder.previewTargets', async () => {
            await previewTargets(outputChannel);
        })
    );

    // Run setup wizard (via CLI)
    context.subscriptions.push(
        vscode.commands.registerCommand('builder.runWizard', async () => {
            await runWizard();
        })
    );
}

async function generateBuilderfile(
    outputChannel: vscode.OutputChannel,
    targetsProvider: BuilderTargetsProvider
): Promise<void> {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (!workspaceFolder) {
        vscode.window.showErrorMessage('No workspace folder open');
        return;
    }

    const workspacePath = workspaceFolder.uri.fsPath;
    const builderfilePath = path.join(workspacePath, 'Builderfile');

    // Check if Builderfile exists
    if (fs.existsSync(builderfilePath)) {
        const overwrite = await vscode.window.showWarningMessage(
            'Builderfile already exists. Overwrite?',
            'Overwrite',
            'Cancel'
        );
        if (overwrite !== 'Overwrite') return;
    }

    await vscode.window.withProgress({
        location: vscode.ProgressLocation.Notification,
        title: 'Analyzing project structure...',
        cancellable: false
    }, async (progress) => {
        progress.report({ increment: 0 });

        // Analyze project
        const analyzer = new ProjectAnalyzer(workspacePath);
        const project = await analyzer.analyze();

        progress.report({ increment: 50, message: 'Generating Builderfile...' });

        if (project.targets.length === 0) {
            vscode.window.showWarningMessage(
                'No targets could be detected. Try running "bldr wizard" for interactive setup.'
            );
            return;
        }

        // Generate Builderfile content
        const content = generateBuilderfileContent(project);
        fs.writeFileSync(builderfilePath, content, 'utf-8');

        // Generate Builderspace if not exists
        const builderspacePath = path.join(workspacePath, 'Builderspace');
        if (!fs.existsSync(builderspacePath)) {
            const spaceContent = generateBuilderspaceContent(project);
            fs.writeFileSync(builderspacePath, spaceContent, 'utf-8');
        }

        // Generate .builderignore if not exists
        const ignorePath = path.join(workspacePath, '.builderignore');
        if (!fs.existsSync(ignorePath)) {
            const ignoreContent = generateBuilderignore(project);
            fs.writeFileSync(ignorePath, ignoreContent, 'utf-8');
        }

        progress.report({ increment: 100 });

        // Open the generated file
        const doc = await vscode.workspace.openTextDocument(builderfilePath);
        await vscode.window.showTextDocument(doc);

        // Refresh explorer
        targetsProvider.refresh();

        vscode.window.showInformationMessage(
            `Generated Builderfile with ${project.targets.length} target(s)`,
            'View Dashboard'
        ).then(action => {
            if (action === 'View Dashboard') {
                vscode.commands.executeCommand('builder.showDashboard');
            }
        });
    });
}

async function previewTargets(outputChannel: vscode.OutputChannel): Promise<void> {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (!workspaceFolder) {
        vscode.window.showErrorMessage('No workspace folder open');
        return;
    }

    await vscode.window.withProgress({
        location: vscode.ProgressLocation.Notification,
        title: 'Scanning project...',
        cancellable: false
    }, async () => {
        const analyzer = new ProjectAnalyzer(workspaceFolder.uri.fsPath);
        const project = await analyzer.analyze();

        if (project.targets.length === 0) {
            vscode.window.showInformationMessage('No targets detected in project.');
            return;
        }

        // Show in output channel
        outputChannel.clear();
        outputChannel.show(true);
        outputChannel.appendLine('='.repeat(60));
        outputChannel.appendLine('  Builder - Detected Targets Preview');
        outputChannel.appendLine('='.repeat(60));
        outputChannel.appendLine('');

        for (const target of project.targets) {
            outputChannel.appendLine(`┌─ 🎯 ${target.name}`);
            outputChannel.appendLine(`│  Type:     ${target.type}`);
            outputChannel.appendLine(`│  Language: ${target.language}`);
            outputChannel.appendLine(`│  Sources:  ${target.sources.length} file(s)`);
            if (target.entry) {
                outputChannel.appendLine(`│  Entry:    ${target.entry}`);
            }
            if (target.deps.length > 0) {
                outputChannel.appendLine(`│  Deps:     ${target.deps.join(', ')}`);
            }
            outputChannel.appendLine('└─');
            outputChannel.appendLine('');
        }

        outputChannel.appendLine('─'.repeat(60));
        outputChannel.appendLine('');
        outputChannel.appendLine('Run "Builder: Generate Builderfile" to create configuration.');

        // Also show quick pick for actions
        const action = await vscode.window.showInformationMessage(
            `Detected ${project.targets.length} target(s): ${project.targets.map(t => t.name).join(', ')}`,
            'Generate Builderfile',
            'Run Wizard'
        );

        if (action === 'Generate Builderfile') {
            vscode.commands.executeCommand('builder.generateBuilderfile');
        } else if (action === 'Run Wizard') {
            vscode.commands.executeCommand('builder.runWizard');
        }
    });
}

async function runWizard(): Promise<void> {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    if (!workspaceFolder) {
        vscode.window.showErrorMessage('No workspace folder open');
        return;
    }

    const cli = findExecutable('bldr');
    if (!cli) {
        vscode.window.showErrorMessage('Builder CLI not found. Please install Builder.');
        return;
    }

    // Run wizard in interactive terminal
    const terminal = vscode.window.createTerminal({
        name: 'Builder Wizard',
        cwd: workspaceFolder.uri.fsPath
    });
    terminal.show();
    terminal.sendText(`${cli} wizard`);
}

function generateBuilderfileContent(project: DetectedProject): string {
    const lines: string[] = [
        '// Builderfile - Auto-generated by Builder VS Code Extension',
        `// Project: ${project.name}`,
        `// Detected languages: ${project.languages.join(', ')}`,
        ''
    ];

    for (const target of project.targets) {
        lines.push(`target("${target.name}") {`);
        lines.push(`    type: ${target.type};`);
        lines.push(`    language: ${target.language};`);
        
        // Sources
        if (target.sources.length <= 3) {
            lines.push(`    sources: [${target.sources.map(s => `"${s}"`).join(', ')}];`);
        } else {
            // Use glob pattern for many sources
            const ext = path.extname(target.sources[0]);
            const dir = path.dirname(target.sources[0]);
            const pattern = dir === '.' ? `*${ext}` : `${dir}/**/*${ext}`;
            lines.push(`    sources: ["${pattern}"];`);
        }

        // Entry point
        if (target.entry) {
            lines.push(`    // entry: "${target.entry}";`);
        }

        // Dependencies
        if (target.deps.length > 0) {
            lines.push(`    deps: [${target.deps.map(d => `":${d}"`).join(', ')}];`);
        }

        // Language-specific config
        if (target.config && Object.keys(target.config).length > 0) {
            lines.push('    config: {');
            for (const [key, value] of Object.entries(target.config)) {
                lines.push(`        "${key}": "${value}",`);
            }
            lines.push('    };');
        }

        // Output
        if (target.type === 'executable') {
            const outputName = target.name.replace(/[^a-zA-Z0-9-_]/g, '-');
            lines.push(`    output: "${outputName}";`);
        }

        lines.push('}');
        lines.push('');
    }

    return lines.join('\n');
}

function generateBuilderspaceContent(project: DetectedProject): string {
    return `// Builderspace - Auto-generated by Builder VS Code Extension

workspace {
    name: "${project.name}";
    version: "1.0.0";

    cache {
        enabled: true;
        directory: ".builder-cache";
    }

    parallel: true;
    maxJobs: 4;
    incremental: true;
}
`;
}

function generateBuilderignore(project: DetectedProject): string {
    const lines: string[] = [
        '# Builder Ignore File',
        '# Patterns here are excluded from source scanning',
        '',
        '# Version control',
        '.git/',
        '.svn/',
        '.hg/',
        '',
        '# Builder cache',
        '.builder-cache/',
        '',
        '# IDE',
        '.idea/',
        '.vscode/',
        '.vs/',
        '',
        '# OS',
        '.DS_Store',
        'Thumbs.db',
        ''
    ];

    // Language-specific ignores
    const langIgnores: Record<string, string[]> = {
        python: ['venv/', '.venv/', '__pycache__/', '*.pyc', '.pytest_cache/'],
        javascript: ['node_modules/', 'dist/', 'build/', '.next/', '.nuxt/'],
        typescript: ['node_modules/', 'dist/', 'build/', '.next/', '.nuxt/'],
        rust: ['target/', 'Cargo.lock'],
        go: ['vendor/', 'bin/'],
        java: ['target/', 'build/', '.gradle/', '*.class'],
        cpp: ['build/', 'cmake-build-*/', '*.o', '*.obj'],
        c: ['build/', '*.o', '*.obj'],
        ruby: ['vendor/bundle/', '.bundle/'],
        elixir: ['_build/', 'deps/', '.elixir_ls/']
    };

    for (const lang of project.languages) {
        const ignores = langIgnores[lang.toLowerCase()];
        if (ignores) {
            lines.push(`# ${lang}`);
            lines.push(...ignores);
            lines.push('');
        }
    }

    return lines.join('\n');
}

