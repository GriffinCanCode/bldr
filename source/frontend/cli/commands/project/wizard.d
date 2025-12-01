module frontend.cli.commands.project.wizard;

import std.stdio;
import std.path;
import std.string : format;
import std.algorithm;
import std.array;
import frontend.cli.input.prompt;
import frontend.cli.control.terminal;
import frontend.cli.display.format;
import infrastructure.analysis.detection.detector;
import infrastructure.analysis.detection.templates;
import infrastructure.config.schema.schema;
import languages.registry : getLanguageLabel;
import infrastructure.utils.logging.logger;

static import std.file;

/// Wizard command - interactive project setup
struct WizardCommand
{
    /// Execute the wizard
    static void execute()
    {
        // Setup terminal for raw input
        enableRawMode();
        scope(exit) disableRawMode();
        
        auto caps = Capabilities.detect();
        auto terminal = Terminal(caps);
        auto formatter = Formatter(caps);
        
        // Title
        terminal.writeln();
        string[] titleContent = [
            "Interactive setup wizard for configuring your Builder project.",
            "Answer a few questions to create optimized build configuration."
        ];
        terminal.writeln(formatter.formatBox("Builder Configuration Wizard", titleContent));
        terminal.writeln();
        
        // Check if files exist
        immutable builderfilePath = "Builderfile";
        immutable builderspacePath = "Builderspace";
        immutable builderignorePath = ".builderignore";
        
        if (std.file.exists(builderfilePath) && std.file.exists(builderspacePath))
        {
            bool overwrite = Prompt.confirm("Build files already exist. Overwrite?", false);
            if (!overwrite)
            {
                Prompt.info("Wizard cancelled. Existing files preserved.");
                return;
            }
            terminal.writeln();
        }
        
        // Auto-detect first
        Prompt.info("Scanning project directory...");
        auto detector = new ProjectDetector(".");
        auto detected = detector.detect();
        terminal.writeln();
        
        // 1. Language selection
        auto language = selectLanguage(detected);
        terminal.writeln();
        
        // 2. Project structure
        auto structure = selectStructure();
        terminal.writeln();
        
        // 3. Package manager (if applicable)
        string packageManager = selectPackageManager(language, detected);
        if (packageManager.length > 0)
            terminal.writeln();
        
        // 4. Caching
        bool enableCaching = Prompt.confirm("Enable caching?", true);
        terminal.writeln();
        
        // 5. Remote execution
        bool enableRemote = Prompt.confirm("Enable remote execution?", false);
        terminal.writeln();
        
        // Generate configuration
        WizardConfig config;
        config.language = language;
        config.structure = structure;
        config.packageManager = packageManager;
        config.enableCaching = enableCaching;
        config.enableRemote = enableRemote;
        config.detected = detected;
        
        terminal.writeln();
        Prompt.info("Generating configuration files...");
        terminal.writeln();
        
        generateFiles(config);
        
        // Success summary
        terminal.writeln();
        terminal.writeln(formatter.formatSeparator('-', 60));
        Prompt.success("Created Builderfile");
        Prompt.success("Created Builderspace");
        Prompt.success("Configured caching");
        Prompt.success("Added .builderignore");
        terminal.writeln(formatter.formatSeparator('-', 60));
        terminal.writeln();
        
        terminal.writeColored("Run ", Color.White);
        terminal.writeColored("'bldr build'", Color.Cyan, Style.Bold);
        terminal.writeColored(" to start building!", Color.White);
        terminal.writeln();
        terminal.writeln();
    }
    
    /// Select primary language
    private static TargetLanguage selectLanguage(ProjectMetadata detected)
    {
        // If languages detected, use as options
        if (!detected.languages.empty)
        {
            auto options = buildLanguageOptions(detected);
            return Prompt.select("What language is your project?", options, 0);
        }
        
        // Build options from most common languages dynamically
        // Using the registry as the source of truth
        SelectOption!TargetLanguage[] options;
        
        // Most popular languages first (common selections for wizard)
        immutable popularLanguages = [
            TargetLanguage.Python,
            TargetLanguage.JavaScript,
            TargetLanguage.TypeScript,
            TargetLanguage.Go,
            TargetLanguage.Rust,
            TargetLanguage.Cpp,
            TargetLanguage.Java,
            TargetLanguage.CSharp,
            TargetLanguage.Ruby
        ];
        
        foreach (lang; popularLanguages)
        {
            options ~= SelectOption!TargetLanguage(getLanguageLabel(lang), lang);
        }
        
        options ~= SelectOption!TargetLanguage("Other", TargetLanguage.Generic);
        
        return Prompt.select("What language is your project?", options, 0);
    }
    
    /// Build language options from detected languages
    private static SelectOption!(TargetLanguage)[] buildLanguageOptions(ProjectMetadata detected)
    {
        SelectOption!(TargetLanguage)[] options;
        
        foreach (langInfo; detected.languages)
        {
            string desc = format("%.0f%% confidence", langInfo.confidence * 100);
            if (langInfo.framework != ProjectFramework.None)
            {
                desc ~= format(", %s", langInfo.framework);
            }
            
            string label = getLanguageLabel(langInfo.language);
            options ~= SelectOption!TargetLanguage(label, langInfo.language, desc);
        }
        
        // Add "Other" option
        options ~= SelectOption!TargetLanguage("Other", TargetLanguage.Generic);
        
        return options;
    }
    
    // Note: getLanguageLabel is now imported from languages.registry
    // This ensures we have a single source of truth for language labels
    
    /// Select project structure type
    private static ProjectStructure selectStructure()
    {
        auto options = [
            SelectOption!ProjectStructure("Single application", ProjectStructure.SingleApp),
            SelectOption!ProjectStructure("Library", ProjectStructure.Library),
            SelectOption!ProjectStructure("Monorepo with multiple services", ProjectStructure.Monorepo)
        ];
        
        return Prompt.select("Project structure?", options, 0);
    }
    
    /// Select package manager for language
    private static string selectPackageManager(TargetLanguage lang, ProjectMetadata detected)
    {
        // Check if language uses package managers
        string[] managers;
        
        switch (lang)
        {
            case TargetLanguage.Python:
                managers = ["Auto-detect", "pip", "poetry", "pipenv", "conda"];
                break;
            case TargetLanguage.JavaScript:
            case TargetLanguage.TypeScript:
                managers = ["Auto-detect", "npm", "yarn", "pnpm", "bun"];
                break;
            case TargetLanguage.Ruby:
                managers = ["Auto-detect", "bundler", "gem"];
                break;
            case TargetLanguage.PHP:
                managers = ["Auto-detect", "composer"];
                break;
            case TargetLanguage.Rust:
                return "cargo"; // Only option
            case TargetLanguage.Go:
                return "go"; // Only option
            default:
                return ""; // No selection needed
        }
        
        if (managers.empty)
            return "";
        
        // Build options
        SelectOption!string[] options;
        foreach (mgr; managers)
        {
            options ~= SelectOption!string(mgr, mgr);
        }
        
        return Prompt.select("Package manager?", options, 0);
    }
    
    /// Generate configuration files
    private static void generateFiles(WizardConfig config)
    {
        // Create custom metadata based on wizard choices
        ProjectMetadata metadata = config.detected;
        
        // Ensure the selected language is in the metadata
        bool hasSelectedLang = false;
        foreach (langInfo; metadata.languages)
        {
            if (langInfo.language == config.language)
            {
                hasSelectedLang = true;
                break;
            }
        }
        
        if (!hasSelectedLang && config.language != TargetLanguage.Generic)
        {
            LanguageInfo langInfo;
            langInfo.language = config.language;
            langInfo.confidence = 1.0;
            metadata.languages ~= langInfo;
        }
        
        auto generator = new TemplateGenerator(metadata);
        
        // Generate Builderfile
        string builderfileContent = generateBuilderfile(config, generator);
        std.file.write("Builderfile", builderfileContent);
        
        // Generate Builderspace
        string builderspaceContent = generateBuilderspace(config, generator);
        std.file.write("Builderspace", builderspaceContent);
        
        // Generate .builderignore
        string builderignoreContent = generateBuilderignore(config, metadata);
        std.file.write(".builderignore", builderignoreContent);
    }
    
    /// Generate Builderfile with wizard config
    private static string generateBuilderfile(WizardConfig config, TemplateGenerator generator)
    {
        string content = "// Builderfile - Generated by 'bldr wizard'\n";
        content ~= format("// Language: %s\n", getLanguageLabel(config.language));
        content ~= format("// Structure: %s\n\n", config.structure);
        
        if (config.language == TargetLanguage.Generic)
        {
            // Generic template
            content ~= "target(\"main\") {\n";
            content ~= "    type: executable;\n";
            content ~= "    sources: [\"src/**/*\"];\n";
            content ~= "}\n";
        }
        else
        {
            // Use template generator
            content ~= generator.generateBuilderfile();
        }
        
        return content;
    }
    
    /// Generate Builderspace with wizard config
    private static string generateBuilderspace(WizardConfig config, TemplateGenerator generator)
    {
        string content = "// Builderspace - Generated by 'bldr wizard'\n\n";
        
        content ~= "workspace {\n";
        content ~= format("    name: \"%s\";\n", config.detected.projectName);
        content ~= "    version: \"1.0.0\";\n";
        
        if (config.enableCaching)
        {
            content ~= "\n    cache {\n";
            content ~= "        enabled: true;\n";
            content ~= "        directory: \".builder-cache\";\n";
            content ~= "    }\n";
        }
        
        if (config.enableRemote)
        {
            content ~= "\n    remote {\n";
            content ~= "        enabled: true;\n";
            content ~= "        // Configure remote execution endpoint\n";
            content ~= "        // endpoint: \"grpc://localhost:8080\";\n";
            content ~= "    }\n";
        }
        
        content ~= "}\n";
        
        return content;
    }
    
    /// Generate .builderignore
    private static string generateBuilderignore(WizardConfig config, ProjectMetadata metadata)
    {
        // Reuse the init command's logic
        import frontend.cli.commands.project.init : InitCommand;
        
        string content = "# Builder Ignore File - Generated by 'bldr wizard'\n";
        content ~= "# Patterns listed here will be ignored during source scanning\n\n";
        
        content ~= "# Version control\n";
        content ~= ".git/\n";
        content ~= ".svn/\n";
        content ~= ".hg/\n\n";
        
        content ~= "# Builder cache\n";
        content ~= ".builder-cache/\n\n";
        
        // Language-specific patterns
        addLanguageIgnorePatterns(content, config.language);
        
        content ~= "# IDE\n";
        content ~= ".idea/\n";
        content ~= ".vscode/\n";
        content ~= ".vs/\n\n";
        
        content ~= "# OS\n";
        content ~= ".DS_Store\n";
        content ~= "Thumbs.db\n\n";
        
        return content;
    }
    
    /// Add language-specific ignore patterns
    private static void addLanguageIgnorePatterns(ref string content, TargetLanguage lang)
    {
        switch (lang)
        {
            case TargetLanguage.Python:
                content ~= "# Python\n";
                content ~= "venv/\n";
                content ~= ".venv/\n";
                content ~= "__pycache__/\n";
                content ~= "*.pyc\n";
                content ~= "*.pyo\n";
                content ~= ".pytest_cache/\n\n";
                break;
            
            case TargetLanguage.JavaScript:
            case TargetLanguage.TypeScript:
                content ~= "# JavaScript/TypeScript\n";
                content ~= "node_modules/\n";
                content ~= "dist/\n";
                content ~= "build/\n";
                content ~= ".next/\n";
                content ~= ".nuxt/\n\n";
                break;
            
            case TargetLanguage.Rust:
                content ~= "# Rust\n";
                content ~= "target/\n";
                content ~= "Cargo.lock\n\n";
                break;
            
            case TargetLanguage.Go:
                content ~= "# Go\n";
                content ~= "vendor/\n";
                content ~= "bin/\n\n";
                break;
            
            case TargetLanguage.Java:
            case TargetLanguage.Kotlin:
            case TargetLanguage.Scala:
                content ~= "# JVM\n";
                content ~= "target/\n";
                content ~= "build/\n";
                content ~= ".gradle/\n";
                content ~= "*.class\n\n";
                break;
            
            case TargetLanguage.CSharp:
            case TargetLanguage.FSharp:
                content ~= "# .NET\n";
                content ~= "bin/\n";
                content ~= "obj/\n";
                content ~= "packages/\n";
                content ~= "*.dll\n";
                content ~= "*.exe\n\n";
                break;
            
            case TargetLanguage.Cpp:
            case TargetLanguage.C:
                content ~= "# C/C++\n";
                content ~= "build/\n";
                content ~= "cmake-build-*/\n";
                content ~= "*.o\n";
                content ~= "*.obj\n";
                content ~= "*.so\n";
                content ~= "*.dll\n\n";
                break;
            
            case TargetLanguage.Ruby:
                content ~= "# Ruby\n";
                content ~= "vendor/bundle/\n";
                content ~= ".bundle/\n\n";
                break;
            
            case TargetLanguage.PHP:
                content ~= "# PHP\n";
                content ~= "vendor/\n";
                content ~= "composer.lock\n\n";
                break;
            
            default:
                // No language-specific patterns
                break;
        }
    }
}

/// Project structure type
enum ProjectStructure
{
    SingleApp,
    Library,
    Monorepo
}

/// Wizard configuration
private struct WizardConfig
{
    TargetLanguage language;
    ProjectStructure structure;
    string packageManager;
    bool enableCaching;
    bool enableRemote;
    ProjectMetadata detected;
}

