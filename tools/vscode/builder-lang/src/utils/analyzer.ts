import * as path from 'path';
import * as fs from 'fs';

export interface DetectedTarget {
    name: string;
    type: 'executable' | 'library' | 'test' | 'custom';
    language: string;
    sources: string[];
    entry?: string;
    deps: string[];
    config?: Record<string, string>;
}

export interface DetectedProject {
    name: string;
    languages: string[];
    targets: DetectedTarget[];
    framework?: string;
    packageManager?: string;
}

interface QuickScanResult {
    languages: string[];
    hasBuilderfile: boolean;
}

// Language detection patterns
const LANGUAGE_PATTERNS: Record<string, { extensions: string[]; manifests: string[]; entryFiles: string[] }> = {
    python: {
        extensions: ['.py'],
        manifests: ['setup.py', 'pyproject.toml', 'requirements.txt', 'Pipfile'],
        entryFiles: ['main.py', 'app.py', '__main__.py', 'cli.py']
    },
    javascript: {
        extensions: ['.js', '.mjs', '.cjs'],
        manifests: ['package.json'],
        entryFiles: ['index.js', 'main.js', 'app.js', 'server.js']
    },
    typescript: {
        extensions: ['.ts', '.tsx'],
        manifests: ['tsconfig.json', 'package.json'],
        entryFiles: ['index.ts', 'main.ts', 'app.ts', 'src/index.ts']
    },
    rust: {
        extensions: ['.rs'],
        manifests: ['Cargo.toml'],
        entryFiles: ['src/main.rs', 'src/lib.rs', 'main.rs']
    },
    go: {
        extensions: ['.go'],
        manifests: ['go.mod', 'go.sum'],
        entryFiles: ['main.go', 'cmd/main.go']
    },
    java: {
        extensions: ['.java'],
        manifests: ['pom.xml', 'build.gradle', 'build.gradle.kts'],
        entryFiles: ['Main.java', 'App.java', 'Application.java']
    },
    cpp: {
        extensions: ['.cpp', '.cc', '.cxx', '.hpp', '.h'],
        manifests: ['CMakeLists.txt', 'Makefile', 'meson.build'],
        entryFiles: ['main.cpp', 'main.cc', 'app.cpp']
    },
    c: {
        extensions: ['.c', '.h'],
        manifests: ['CMakeLists.txt', 'Makefile', 'meson.build'],
        entryFiles: ['main.c', 'app.c']
    },
    ruby: {
        extensions: ['.rb'],
        manifests: ['Gemfile', 'Rakefile', '*.gemspec'],
        entryFiles: ['main.rb', 'app.rb', 'lib/*.rb']
    },
    elixir: {
        extensions: ['.ex', '.exs'],
        manifests: ['mix.exs'],
        entryFiles: ['lib/*.ex']
    },
    swift: {
        extensions: ['.swift'],
        manifests: ['Package.swift'],
        entryFiles: ['main.swift', 'Sources/*/main.swift']
    },
    kotlin: {
        extensions: ['.kt', '.kts'],
        manifests: ['build.gradle.kts', 'build.gradle'],
        entryFiles: ['Main.kt', 'App.kt']
    },
    csharp: {
        extensions: ['.cs'],
        manifests: ['*.csproj', '*.sln'],
        entryFiles: ['Program.cs', 'Main.cs']
    },
    zig: {
        extensions: ['.zig'],
        manifests: ['build.zig'],
        entryFiles: ['src/main.zig', 'main.zig']
    }
};

// Framework detection patterns
const FRAMEWORK_PATTERNS: Record<string, { files: string[]; deps: string[] }> = {
    react: { files: [], deps: ['react', 'react-dom'] },
    vue: { files: ['vue.config.js'], deps: ['vue'] },
    angular: { files: ['angular.json'], deps: ['@angular/core'] },
    nextjs: { files: ['next.config.js', 'next.config.mjs'], deps: ['next'] },
    django: { files: ['manage.py'], deps: ['django'] },
    flask: { files: [], deps: ['flask'] },
    fastapi: { files: [], deps: ['fastapi'] },
    express: { files: [], deps: ['express'] },
    rails: { files: ['config/routes.rb'], deps: [] },
    phoenix: { files: [], deps: [':phoenix'] },
    spring: { files: [], deps: ['org.springframework'] },
    gin: { files: [], deps: ['github.com/gin-gonic/gin'] }
};

export class ProjectAnalyzer {
    private projectDir: string;
    private ignoreDirs = new Set([
        'node_modules', '.git', '.svn', 'vendor', 'venv', '.venv',
        '__pycache__', 'target', 'build', 'dist', '.builder-cache',
        'bin', 'obj', '.idea', '.vscode', 'coverage', '.next', '.nuxt'
    ]);

    constructor(projectDir: string) {
        this.projectDir = projectDir;
    }

    async quickScan(): Promise<QuickScanResult> {
        const languages: string[] = [];
        const hasBuilderfile = fs.existsSync(path.join(this.projectDir, 'Builderfile'));

        for (const [lang, patterns] of Object.entries(LANGUAGE_PATTERNS)) {
            // Check manifests
            for (const manifest of patterns.manifests) {
                if (manifest.includes('*')) {
                    const files = this.findFiles(this.projectDir, manifest.replace('*', ''));
                    if (files.length > 0) {
                        languages.push(lang);
                        break;
                    }
                } else if (fs.existsSync(path.join(this.projectDir, manifest))) {
                    languages.push(lang);
                    break;
                }
            }
        }

        return { languages, hasBuilderfile };
    }

    async analyze(): Promise<DetectedProject> {
        const project: DetectedProject = {
            name: path.basename(this.projectDir),
            languages: [],
            targets: []
        };

        // Detect languages
        const langFiles = new Map<string, string[]>();
        await this.scanDirectory(this.projectDir, langFiles);

        for (const [lang, files] of langFiles) {
            if (files.length > 0) {
                project.languages.push(lang);
            }
        }

        // Detect package manager
        project.packageManager = this.detectPackageManager();

        // Detect framework
        project.framework = await this.detectFramework();

        // Generate targets based on detected structure
        project.targets = this.generateTargets(langFiles, project);

        return project;
    }

    private async scanDirectory(dir: string, langFiles: Map<string, string[]>, depth = 0): Promise<void> {
        if (depth > 10) return;

        let entries: fs.Dirent[];
        try {
            entries = fs.readdirSync(dir, { withFileTypes: true });
        } catch {
            return;
        }

        for (const entry of entries) {
            if (entry.isDirectory()) {
                if (!this.ignoreDirs.has(entry.name)) {
                    await this.scanDirectory(path.join(dir, entry.name), langFiles, depth + 1);
                }
            } else if (entry.isFile()) {
                const ext = path.extname(entry.name);
                for (const [lang, patterns] of Object.entries(LANGUAGE_PATTERNS)) {
                    if (patterns.extensions.includes(ext)) {
                        if (!langFiles.has(lang)) {
                            langFiles.set(lang, []);
                        }
                        const relativePath = path.relative(this.projectDir, path.join(dir, entry.name));
                        langFiles.get(lang)!.push(relativePath);
                    }
                }
            }
        }
    }

    private detectPackageManager(): string | undefined {
        const managers: Record<string, string> = {
            'package-lock.json': 'npm',
            'yarn.lock': 'yarn',
            'pnpm-lock.yaml': 'pnpm',
            'bun.lockb': 'bun',
            'Pipfile.lock': 'pipenv',
            'poetry.lock': 'poetry',
            'Cargo.lock': 'cargo',
            'go.sum': 'go',
            'Gemfile.lock': 'bundler',
            'composer.lock': 'composer'
        };

        for (const [file, manager] of Object.entries(managers)) {
            if (fs.existsSync(path.join(this.projectDir, file))) {
                return manager;
            }
        }

        return undefined;
    }

    private async detectFramework(): Promise<string | undefined> {
        // Check framework-specific files
        for (const [framework, patterns] of Object.entries(FRAMEWORK_PATTERNS)) {
            for (const file of patterns.files) {
                if (fs.existsSync(path.join(this.projectDir, file))) {
                    return framework;
                }
            }
        }

        // Check package.json dependencies
        const pkgPath = path.join(this.projectDir, 'package.json');
        if (fs.existsSync(pkgPath)) {
            try {
                const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf-8'));
                const allDeps = { ...pkg.dependencies, ...pkg.devDependencies };
                
                for (const [framework, patterns] of Object.entries(FRAMEWORK_PATTERNS)) {
                    for (const dep of patterns.deps) {
                        if (allDeps[dep]) {
                            return framework;
                        }
                    }
                }
            } catch {
                // Ignore parse errors
            }
        }

        return undefined;
    }

    private generateTargets(langFiles: Map<string, string[]>, project: DetectedProject): DetectedTarget[] {
        const targets: DetectedTarget[] = [];

        for (const [lang, files] of langFiles) {
            if (files.length === 0) continue;

            const patterns = LANGUAGE_PATTERNS[lang];
            
            // Find entry point
            let entryFile: string | undefined;
            for (const entryPattern of patterns.entryFiles) {
                const found = files.find(f => {
                    const normalized = f.replace(/\\/g, '/');
                    return normalized === entryPattern || normalized.endsWith('/' + entryPattern);
                });
                if (found) {
                    entryFile = found;
                    break;
                }
            }

            // Check for test files
            const testFiles = files.filter(f => 
                f.includes('test') || f.includes('spec') || f.includes('_test.') || f.includes('.test.')
            );
            const srcFiles = files.filter(f => !testFiles.includes(f));

            // Create main target
            if (srcFiles.length > 0) {
                const targetName = this.generateTargetName(lang, project);
                const targetType = this.inferTargetType(lang, project, entryFile);

                targets.push({
                    name: targetName,
                    type: targetType,
                    language: lang,
                    sources: srcFiles,
                    entry: entryFile,
                    deps: [],
                    config: this.getLanguageConfig(lang, project)
                });
            }

            // Create test target if test files exist
            if (testFiles.length > 0) {
                targets.push({
                    name: `${lang}-tests`,
                    type: 'test',
                    language: lang,
                    sources: testFiles,
                    deps: srcFiles.length > 0 ? [`:${this.generateTargetName(lang, project)}`] : [],
                    config: this.getTestConfig(lang)
                });
            }
        }

        return targets;
    }

    private generateTargetName(lang: string, project: DetectedProject): string {
        // If single language, use project name
        if (project.languages.length === 1) {
            return project.name.toLowerCase().replace(/[^a-z0-9]/g, '-');
        }
        // Multiple languages: prefix with language
        return `${lang}-${project.name.toLowerCase().replace(/[^a-z0-9]/g, '-')}`;
    }

    private inferTargetType(lang: string, project: DetectedProject, entry?: string): 'executable' | 'library' {
        // Framework-specific
        if (project.framework) {
            const appFrameworks = ['react', 'vue', 'angular', 'nextjs', 'django', 'flask', 'fastapi', 'express', 'rails', 'phoenix', 'gin'];
            if (appFrameworks.includes(project.framework)) {
                return 'executable';
            }
        }

        // Entry point suggests executable
        if (entry) return 'executable';

        // Language-specific defaults
        const libLangs = ['ruby', 'elixir'];
        if (libLangs.includes(lang)) return 'library';

        return 'executable';
    }

    private getLanguageConfig(lang: string, project: DetectedProject): Record<string, string> | undefined {
        const configs: Record<string, Record<string, string>> = {
            typescript: { target: 'es2020', module: 'esm', strict: 'true' },
            python: { interpreter: 'python3' },
            rust: { edition: '2021', profile: 'release' },
            go: { goVersion: '1.21' },
            cpp: { standard: 'c++17', optimization: 'O2' },
            java: { sourceVersion: '17', targetVersion: '17' }
        };

        return configs[lang];
    }

    private getTestConfig(lang: string): Record<string, string> | undefined {
        const configs: Record<string, Record<string, string>> = {
            python: { framework: 'pytest' },
            javascript: { framework: 'jest' },
            typescript: { framework: 'jest' },
            rust: { framework: 'cargo-test' },
            go: { framework: 'go-test' }
        };

        return configs[lang];
    }

    private findFiles(dir: string, suffix: string): string[] {
        const results: string[] = [];
        try {
            const entries = fs.readdirSync(dir, { withFileTypes: true });
            for (const entry of entries) {
                if (entry.isFile() && entry.name.endsWith(suffix)) {
                    results.push(path.join(dir, entry.name));
                }
            }
        } catch {
            // Ignore errors
        }
        return results;
    }
}

