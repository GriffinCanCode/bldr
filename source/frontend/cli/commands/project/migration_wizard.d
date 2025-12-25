module frontend.cli.commands.project.migration_wizard;

import std.stdio;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.conv;
import std.file : exists, isDir, dirEntries, SpanMode, readText;
static import std.file;

import frontend.cli.input.prompt;
import frontend.cli.control.terminal;
import frontend.cli.display.format;
import infrastructure.migration;
import infrastructure.migration.core.common;
import infrastructure.utils.logging.logger;

/// Interactive Migration Wizard for converting build configurations
/// Provides guided conversion with explanations, edge case handling, and validation
struct MigrationWizard
{
    private Terminal terminal;
    private Formatter formatter;
    private Capabilities caps;
    
    /// Detected build files in project
    private DetectedBuildFile[] detectedFiles;
    
    /// Current migration context
    private MigrationContext context;
    
    /// Initialize wizard
    void initialize() @system
    {
        caps = Capabilities.detect();
        terminal = Terminal(caps);
        formatter = Formatter(caps);
    }
    
    /// Execute the interactive migration wizard
    static int execute(string[] args) @system
    {
        MigrationWizard wizard;
        wizard.initialize();
        return wizard.run(args);
    }
    
    /// Main wizard execution flow
    private int run(string[] args) @system
    {
        import core.sys.posix.unistd : isatty, STDIN_FILENO;
        
        // Check if running interactively - if not, provide helpful message
        version(Posix)
        {
            if (!isatty(STDIN_FILENO))
            {
                Logger.error("Migration wizard requires interactive terminal.");
                Logger.info("Use non-interactive mode instead: bldr migrate --auto <file>");
                Logger.info("Or specify build system: bldr migrate --no-wizard --from=<system> <file>");
                return 1;
            }
        }
        
        // Setup terminal for raw input
        enableRawMode();
        scope(exit) disableRawMode();
        
        // Show welcome banner
        showWelcome();
        
        // Parse directory argument
        string projectDir = ".";
        foreach (arg; args)
        {
            if (!arg.startsWith("--") && !arg.startsWith("-") && arg != "migrate-wizard")
            {
                projectDir = arg;
                break;
            }
        }
        
        if (!exists(projectDir))
        {
            showError("Directory does not exist: " ~ projectDir);
            return 1;
        }
        
        // Step 1: Scan for build files
        if (!scanBuildFiles(projectDir))
        {
            showInfo("No build files detected. Use 'bldr wizard' to create a new project.");
            return 1;
        }
        
        // Step 2: Select build system
        auto selectedFile = selectBuildFile();
        if (selectedFile is null)
        {
            showInfo("Migration cancelled.");
            return 0;
        }
        
        // Step 3: Get migrator and show system info
        auto migrator = MigratorFactory.create(selectedFile.system);
        if (migrator is null)
        {
            showError("Unsupported build system: " ~ selectedFile.system);
            return 1;
        }
        
        showSystemInfo(migrator);
        
        // Step 4: Perform migration with explanation
        auto migrationResult = performMigration(migrator, selectedFile.path);
        if (migrationResult is null)
            return 1;
        
        // Step 5: Handle edge cases and conflicts
        handleEdgeCases(migrationResult);
        
        // Step 6: Show translation explanation
        showTranslationExplanation(migrationResult, selectedFile);
        
        // Step 7: Validate configuration
        auto validationResult = validateMigration(migrationResult);
        showValidationResults(validationResult);
        
        // Step 8: Preview and confirm
        if (!previewAndConfirm(migrationResult))
        {
            showInfo("Migration cancelled. No files were written.");
            return 0;
        }
        
        // Step 9: Write output files
        return writeOutput(migrationResult);
    }
    
    /// Show welcome banner
    private void showWelcome() @system
    {
        terminal.writeln();
        string[] content = [
            "Convert your existing build configuration to Builder format.",
            "This wizard will guide you through the migration process,",
            "explaining each translation and handling edge cases."
        ];
        terminal.writeln(formatter.formatBox("Migration Wizard", content));
        terminal.writeln();
    }
    
    /// Scan project for existing build files
    private bool scanBuildFiles(string projectDir) @system
    {
        showInfo("Scanning for build files...");
        terminal.writeln();
        
        detectedFiles = [];
        
        // Check all supported build systems
        auto registry = getMigratorRegistry();
        foreach (migrator; registry.allMigrators())
        {
            foreach (fileName; migrator.defaultFileNames())
            {
                string fullPath = buildPath(projectDir, fileName);
                if (exists(fullPath))
                {
                    DetectedBuildFile detected;
                    detected.path = fullPath;
                    detected.fileName = fileName;
                    detected.system = migrator.systemName();
                    detected.description = migrator.description();
                    detected.confidence = calculateConfidence(fullPath, migrator);
                    detectedFiles ~= detected;
                }
            }
        }
        
        // Sort by confidence
        detectedFiles.sort!((a, b) => a.confidence > b.confidence);
        
        if (detectedFiles.length > 0)
        {
            showSuccess("Found " ~ detectedFiles.length.to!string ~ " build file(s):");
            terminal.writeln();
            
            foreach (i, file; detectedFiles)
            {
                terminal.write("  ");
                terminal.writeColored(to!string(i + 1) ~ ". ", Color.Cyan);
                terminal.writeColored(file.fileName, Color.White, Style.Bold);
                terminal.write(" ");
                terminal.writeColored("(" ~ file.system ~ ", " ~ 
                    format("%.0f%%", file.confidence * 100) ~ " confidence)", 
                    Color.BrightBlack);
                terminal.writeln();
            }
            terminal.writeln();
        }
        
        return detectedFiles.length > 0;
    }
    
    /// Calculate confidence for a detected build file
    private float calculateConfidence(string filePath, IMigrator migrator) @system
    {
        float confidence = 0.5; // Base confidence
        
        try
        {
            string content = readText(filePath);
            
            // Check for system-specific indicators
            switch (migrator.systemName())
            {
                case "bazel":
                    if (content.indexOf("cc_binary") >= 0 || 
                        content.indexOf("py_binary") >= 0 ||
                        content.indexOf("java_binary") >= 0)
                        confidence += 0.4;
                    break;
                    
                case "cmake":
                    if (content.indexOf("cmake_minimum_required") >= 0)
                        confidence += 0.3;
                    if (content.indexOf("project(") >= 0)
                        confidence += 0.2;
                    break;
                    
                case "maven":
                    if (content.indexOf("<project") >= 0 && 
                        content.indexOf("xmlns=\"http://maven.apache.org/POM") >= 0)
                        confidence += 0.45;
                    break;
                    
                case "gradle":
                    if (content.indexOf("plugins {") >= 0 || 
                        content.indexOf("apply plugin:") >= 0)
                        confidence += 0.4;
                    break;
                    
                case "cargo":
                    if (content.indexOf("[package]") >= 0)
                        confidence += 0.4;
                    break;
                    
                case "npm":
                    if (content.indexOf("\"name\"") >= 0 && 
                        content.indexOf("\"version\"") >= 0)
                        confidence += 0.4;
                    break;
                    
                default:
                    confidence += 0.2;
            }
        }
        catch (Exception e)
        {
            // Could not read file
        }
        
        return min(confidence, 1.0);
    }
    
    /// Interactive selection of build file to migrate
    private DetectedBuildFile* selectBuildFile() @system
    {
        if (detectedFiles.length == 1)
        {
            // Single file - confirm
            bool proceed = Prompt.confirm(
                "Migrate from " ~ detectedFiles[0].system ~ " (" ~ 
                detectedFiles[0].fileName ~ ")?", true);
            return proceed ? &detectedFiles[0] : null;
        }
        
        // Multiple files - let user select
        SelectOption!(size_t)[] options;
        foreach (i, file; detectedFiles)
        {
            string desc = format("%.0f%% confidence", file.confidence * 100);
            options ~= SelectOption!size_t(
                file.fileName ~ " (" ~ file.system ~ ")", i, desc);
        }
        options ~= SelectOption!size_t("Cancel", size_t.max);
        
        size_t selected = Prompt.select("Which build file to migrate?", options, 0);
        
        if (selected == size_t.max)
            return null;
        
        return &detectedFiles[selected];
    }
    
    /// Show detailed information about the selected build system
    private void showSystemInfo(IMigrator migrator) @system
    {
        terminal.writeln();
        terminal.writeln(formatter.formatSeparator('-', 60));
        terminal.writeColored("  Build System: ", Color.White);
        terminal.writeColored(migrator.systemName().toUpper(), Color.Cyan, Style.Bold);
        terminal.writeln();
        terminal.writeln(formatter.formatSeparator('-', 60));
        terminal.writeln();
        
        // Supported features
        terminal.writeColored("✓ Supported Features:\n", Color.Green);
        foreach (feature; migrator.supportedFeatures())
        {
            terminal.write("    • ");
            terminal.writeln(feature);
        }
        terminal.writeln();
        
        // Limitations
        terminal.writeColored("⚠ Limitations (may need manual review):\n", Color.Yellow);
        foreach (limitation; migrator.limitations())
        {
            terminal.write("    • ");
            terminal.writeln(limitation);
        }
        terminal.writeln();
        
        // Ask to proceed
        if (!Prompt.confirm("Continue with migration?", true))
        {
            showInfo("Migration cancelled.");
        }
        terminal.writeln();
    }
    
    /// Perform the actual migration
    private MigrationResult* performMigration(IMigrator migrator, string inputPath) @system
    {
        showInfo("Analyzing build configuration...");
        terminal.writeln();
        
        auto result = migrator.migrate(inputPath);
        
        if (result.isErr)
        {
            showError("Migration failed: " ~ result.unwrapErr().message);
            return null;
        }
        
        context.migrationResult = result.unwrap();
        context.sourceSystem = migrator.systemName();
        context.sourcePath = inputPath;
        
        showSuccess("Found " ~ context.migrationResult.targets.length.to!string ~ " target(s)");
        terminal.writeln();
        
        return &context.migrationResult;
    }
    
    /// Handle edge cases with user prompts
    private void handleEdgeCases(MigrationResult* result) @system
    {
        // Check for conflicts with existing files
        if (exists("Builderfile"))
        {
            terminal.writeln();
            terminal.writeColored("⚠ ", Color.Yellow);
            terminal.writeln("Builderfile already exists!");
            
            string[] conflictOptions = [
                "Overwrite existing file",
                "Create as Builderfile.migrated",
                "Cancel migration"
            ];
            
            SelectOption!string[] options;
            foreach (opt; conflictOptions)
                options ~= SelectOption!string(opt, opt);
            
            string choice = Prompt.select("How to handle existing Builderfile?", options, 1);
            
            if (choice == conflictOptions[2])
            {
                context.cancelled = true;
                return;
            }
            else if (choice == conflictOptions[1])
            {
                context.outputPath = "Builderfile.migrated";
            }
            terminal.writeln();
        }
        
        // Handle targets with issues
        foreach (ref target; result.targets)
        {
            // Check for empty sources
            if (target.sources.length == 0)
            {
                terminal.writeColored("⚠ ", Color.Yellow);
                terminal.writeln("Target '" ~ target.name ~ "' has no sources detected");
                
                string defaultPattern = getDefaultSourcePattern(target.language);
                string userPattern = Prompt.input(
                    "Enter source pattern for '" ~ target.name ~ "'",
                    defaultPattern);
                
                if (userPattern.length > 0)
                    target.sources = [userPattern];
                
                terminal.writeln();
            }
            
            // Check for unresolved dependencies
            foreach (i, dep; target.dependencies)
            {
                if (dep.startsWith("//") || dep.startsWith("@"))
                {
                    terminal.writeColored("⚠ ", Color.Yellow);
                    terminal.writeln("External dependency detected: " ~ dep);
                    
                    string resolvedDep = Prompt.input(
                        "Enter Builder-compatible reference (or leave empty to keep)",
                        dep.replace("//", "").replace("@", ""));
                    
                    if (resolvedDep.length > 0)
                        target.dependencies[i] = resolvedDep;
                    
                    terminal.writeln();
                }
            }
        }
        
        // Handle unsupported features
        auto errorWarnings = result.warnings.filter!(
            w => w.level == WarningLevel.Error).array;
        
        if (errorWarnings.length > 0)
        {
            terminal.writeln();
            terminal.writeColored("⚠ Unsupported Features Detected:\n", Color.Yellow, Style.Bold);
            
            foreach (warning; errorWarnings)
            {
                terminal.write("    • ");
                terminal.writeln(warning.message);
                
                if (warning.suggestions.length > 0)
                {
                    foreach (suggestion; warning.suggestions)
                    {
                        terminal.writeColored("      → ", Color.Cyan);
                        terminal.writeln(suggestion);
                    }
                }
            }
            
            terminal.writeln();
            if (!Prompt.confirm("Continue despite unsupported features?", true))
            {
                context.cancelled = true;
                return;
            }
            terminal.writeln();
        }
    }
    
    /// Get default source pattern for a language
    private string getDefaultSourcePattern(TargetLanguage lang) @safe
    {
        import infrastructure.config.schema.schema : TargetLanguage;
        
        switch (lang)
        {
            case TargetLanguage.Cpp:
            case TargetLanguage.C:
                return "src/**/*.{c,cpp,cc,h,hpp}";
            case TargetLanguage.Java:
                return "src/main/java/**/*.java";
            case TargetLanguage.Python:
                return "src/**/*.py";
            case TargetLanguage.Go:
                return "**/*.go";
            case TargetLanguage.Rust:
                return "src/**/*.rs";
            case TargetLanguage.TypeScript:
            case TargetLanguage.JavaScript:
                return "src/**/*.{ts,tsx,js,jsx}";
            default:
                return "src/**/*";
        }
    }
    
    /// Show detailed translation explanation
    private void showTranslationExplanation(MigrationResult* result, DetectedBuildFile* sourceFile) @system
    {
        terminal.writeln();
        terminal.writeln(formatter.formatSeparator('=', 60));
        terminal.writeColored("  Translation Breakdown\n", Color.Cyan, Style.Bold);
        terminal.writeln(formatter.formatSeparator('=', 60));
        terminal.writeln();
        
        // Show each target translation
        foreach (i, target; result.targets)
        {
            showTargetTranslation(target, sourceFile.system, i + 1);
        }
        
        // Global configuration
        if (result.globalConfig.length > 0)
        {
            terminal.writeColored("Global Configuration:\n", Color.White, Style.Bold);
            foreach (key, value; result.globalConfig)
            {
                terminal.write("    ");
                terminal.writeColored(key, Color.Cyan);
                terminal.write(": ");
                terminal.writeln(value);
            }
            terminal.writeln();
        }
        
        terminal.writeln(formatter.formatSeparator('-', 60));
        terminal.writeln();
    }
    
    /// Show translation for a single target
    private void showTargetTranslation(ref const MigrationTarget target, 
                                        string sourceSystem, size_t idx) @system
    {
        import infrastructure.config.schema.schema : TargetType, TargetLanguage;
        
        terminal.writeColored(format("Target %d: ", idx), Color.BrightBlack);
        terminal.writeColored(target.name, Color.White, Style.Bold);
        terminal.writeln();
        terminal.writeln();
        
        // Type translation
        string sourceType = getSourceSystemType(sourceSystem, target.type);
        terminal.write("    ");
        terminal.writeColored(sourceType, Color.Yellow);
        terminal.writeColored(" → ", Color.BrightBlack);
        terminal.writeColored("type: " ~ targetTypeString(target.type), Color.Green);
        terminal.writeln();
        
        // Language translation
        terminal.write("    ");
        terminal.writeColored("(inferred)", Color.BrightBlack);
        terminal.writeColored(" → ", Color.BrightBlack);
        terminal.writeColored("language: " ~ targetLangString(target.language), Color.Green);
        terminal.writeln();
        
        // Sources translation
        if (target.sources.length > 0)
        {
            terminal.write("    ");
            terminal.writeColored("sources", Color.Yellow);
            terminal.writeColored(" → ", Color.BrightBlack);
            terminal.writeColored("sources: " ~ formatSourcesList(target.sources), Color.Green);
            terminal.writeln();
        }
        
        // Dependencies translation
        if (target.dependencies.length > 0)
        {
            terminal.write("    ");
            terminal.writeColored(getDepsKeyword(sourceSystem), Color.Yellow);
            terminal.writeColored(" → ", Color.BrightBlack);
            terminal.writeColored("deps: " ~ formatDepsList(target.dependencies), Color.Green);
            terminal.writeln();
        }
        
        // Flags translation
        if (target.flags.length > 0)
        {
            terminal.write("    ");
            terminal.writeColored(getFlagsKeyword(sourceSystem), Color.Yellow);
            terminal.writeColored(" → ", Color.BrightBlack);
            terminal.writeColored("flags: " ~ formatFlagsList(target.flags), Color.Green);
            terminal.writeln();
        }
        
        // Metadata (preserved as comments)
        if (target.metadata.length > 0)
        {
            terminal.write("    ");
            terminal.writeColored("metadata preserved as comments:", Color.BrightBlack);
            terminal.writeln();
            foreach (key, value; target.metadata)
            {
                terminal.write("      // ");
                terminal.writeColored(key ~ ": " ~ value, Color.BrightBlack);
                terminal.writeln();
            }
        }
        
        terminal.writeln();
    }
    
    /// Get source system type keyword
    private string getSourceSystemType(string system, TargetType type) @safe
    {
        import infrastructure.config.schema.schema : TargetType;
        
        switch (system)
        {
            case "bazel":
                return type == TargetType.Executable ? "cc_binary" : 
                       type == TargetType.Library ? "cc_library" : 
                       type == TargetType.Test ? "cc_test" : "rule";
            case "cmake":
                return type == TargetType.Executable ? "add_executable" : "add_library";
            case "maven":
                return "pom.xml packaging";
            case "gradle":
                return "gradle plugin";
            case "make":
                return "make target";
            case "cargo":
                return type == TargetType.Executable ? "[[bin]]" : "[lib]";
            case "npm":
                return "package.json";
            default:
                return system ~ " target";
        }
    }
    
    /// Get deps keyword for source system
    private string getDepsKeyword(string system) @safe
    {
        switch (system)
        {
            case "bazel": return "deps";
            case "cmake": return "target_link_libraries";
            case "maven": return "<dependencies>";
            case "gradle": return "dependencies";
            case "cargo": return "[dependencies]";
            case "npm": return "dependencies";
            default: return "dependencies";
        }
    }
    
    /// Get flags keyword for source system
    private string getFlagsKeyword(string system) @safe
    {
        switch (system)
        {
            case "bazel": return "copts/linkopts";
            case "cmake": return "target_compile_options";
            case "maven": return "compilerArgs";
            case "gradle": return "compileOptions";
            case "cargo": return "[profile]";
            default: return "flags";
        }
    }
    
    /// Format sources list for display
    private string formatSourcesList(const string[] sources) @safe
    {
        if (sources.length == 1)
            return "[\"" ~ sources[0] ~ "\"]";
        return "[" ~ sources.length.to!string ~ " patterns]";
    }
    
    /// Format deps list for display
    private string formatDepsList(const string[] deps) @safe
    {
        if (deps.length <= 2)
            return "[\"" ~ deps.join("\", \"") ~ "\"]";
        return "[" ~ deps.length.to!string ~ " dependencies]";
    }
    
    /// Format flags list for display
    private string formatFlagsList(const string[] flags) @safe
    {
        if (flags.length <= 3)
            return "[\"" ~ flags.join("\", \"") ~ "\"]";
        return "[" ~ flags.length.to!string ~ " flags]";
    }
    
    /// Convert target type to string
    private string targetTypeString(TargetType t) @safe
    {
        import infrastructure.config.schema.schema : TargetType;
        
        final switch (t)
        {
            case TargetType.Executable: return "executable";
            case TargetType.Library: return "library";
            case TargetType.Test: return "test";
            case TargetType.Custom: return "custom";
            case TargetType.Shell: return "shell";
        }
    }
    
    /// Convert target language to string
    private string targetLangString(TargetLanguage l) @safe
    {
        import std.conv : to;
        import std.uni : toLower;
        return l.to!string.toLower();
    }
    
    /// Validate the migration result
    private ValidationResult validateMigration(MigrationResult* result) @system
    {
        ValidationResult validation;
        
        foreach (target; result.targets)
        {
            // Check required fields
            if (target.name.length == 0)
            {
                validation.errors ~= "Target has no name";
            }
            
            if (target.sources.length == 0)
            {
                validation.warnings ~= "Target '" ~ target.name ~ "' has no sources";
            }
            
            // Check for circular dependencies (basic)
            foreach (dep; target.dependencies)
            {
                if (dep == target.name)
                {
                    validation.errors ~= "Target '" ~ target.name ~ 
                        "' has circular dependency on itself";
                }
            }
            
            // Check source patterns are valid
            foreach (source; target.sources)
            {
                if (source.indexOf('\0') >= 0)
                {
                    validation.errors ~= "Invalid source pattern in target '" ~ target.name ~ "'";
                }
            }
        }
        
        // Check for duplicate target names
        string[] names;
        foreach (target; result.targets)
        {
            if (names.canFind(target.name))
            {
                validation.errors ~= "Duplicate target name: " ~ target.name;
            }
            names ~= target.name;
        }
        
        validation.valid = validation.errors.length == 0;
        return validation;
    }
    
    /// Show validation results
    private void showValidationResults(ValidationResult validation) @system
    {
        terminal.writeColored("Validation Results:\n", Color.White, Style.Bold);
        
        if (validation.valid)
        {
            terminal.writeColored("  ✓ ", Color.Green, Style.Bold);
            terminal.writeln("Configuration is valid");
        }
        else
        {
            terminal.writeColored("  ✗ ", Color.Red, Style.Bold);
            terminal.writeln("Configuration has issues");
        }
        
        foreach (error; validation.errors)
        {
            terminal.writeColored("    ERROR: ", Color.Red);
            terminal.writeln(error);
        }
        
        foreach (warning; validation.warnings)
        {
            terminal.writeColored("    WARN: ", Color.Yellow);
            terminal.writeln(warning);
        }
        
        terminal.writeln();
    }
    
    /// Preview generated Builderfile and confirm
    private bool previewAndConfirm(MigrationResult* result) @system
    {
        if (context.cancelled)
            return false;
        
        // Generate the Builderfile content
        auto emitter = BuilderfileEmitter();
        string content = emitter.emit(*result);
        context.generatedContent = content;
        
        // Show preview
        terminal.writeln(formatter.formatSeparator('=', 60));
        terminal.writeColored("  Generated Builderfile Preview\n", Color.Cyan, Style.Bold);
        terminal.writeln(formatter.formatSeparator('=', 60));
        terminal.writeln();
        
        // Show content with syntax highlighting (basic)
        foreach (line; content.splitLines())
        {
            if (line.startsWith("//"))
            {
                terminal.writeColored(line, Color.BrightBlack);
            }
            else if (line.indexOf("target(") >= 0)
            {
                terminal.writeColored(line, Color.Cyan, Style.Bold);
            }
            else if (line.indexOf(":") >= 0 && !line.startsWith(" "))
            {
                auto parts = line.findSplit(":");
                terminal.writeColored(parts[0], Color.Yellow);
                terminal.write(":");
                terminal.writeln(parts[2]);
                continue;
            }
            else
            {
                terminal.write(line);
            }
            terminal.writeln();
        }
        
        terminal.writeln();
        terminal.writeln(formatter.formatSeparator('-', 60));
        terminal.writeln();
        
        // Summary
        terminal.writeColored("Summary:\n", Color.White, Style.Bold);
        terminal.write("  • Targets: ");
        terminal.writeColored(result.targets.length.to!string, Color.Cyan);
        terminal.writeln();
        terminal.write("  • Warnings: ");
        terminal.writeColored(result.warnings.length.to!string, 
            result.warnings.length > 0 ? Color.Yellow : Color.Green);
        terminal.writeln();
        terminal.write("  • Output: ");
        terminal.writeColored(context.outputPath.length > 0 ? 
            context.outputPath : "Builderfile", Color.Cyan);
        terminal.writeln();
        terminal.writeln();
        
        return Prompt.confirm("Write Builderfile?", true);
    }
    
    /// Write output files
    private int writeOutput(MigrationResult* result) @system
    {
        string outputPath = context.outputPath.length > 0 ? 
            context.outputPath : "Builderfile";
        
        try
        {
            std.file.write(outputPath, context.generatedContent);
            
            terminal.writeln();
            showSuccess("Created " ~ outputPath);
            
            // Show next steps
            terminal.writeln();
            terminal.writeColored("Next Steps:\n", Color.White, Style.Bold);
            terminal.write("  1. ");
            terminal.writeln("Review the generated Builderfile");
            terminal.write("  2. ");
            terminal.writeln("Address any commented warnings");
            terminal.write("  3. ");
            terminal.write("Test with: ");
            terminal.writeColored("bldr build\n", Color.Cyan);
            terminal.writeln();
            
            return 0;
        }
        catch (Exception e)
        {
            showError("Failed to write file: " ~ e.msg);
            return 1;
        }
    }
    
    // Helper display methods
    private void showInfo(string msg) @system
    {
        terminal.writeColored("ℹ ", Color.Cyan);
        terminal.writeln(msg);
    }
    
    private void showSuccess(string msg) @system
    {
        terminal.writeColored("✓ ", Color.Green, Style.Bold);
        terminal.writeln(msg);
    }
    
    private void showError(string msg) @system
    {
        terminal.writeColored("✗ ", Color.Red, Style.Bold);
        terminal.writeln(msg);
    }
}

/// Detected build file information
private struct DetectedBuildFile
{
    string path;
    string fileName;
    string system;
    string description;
    float confidence;
}

/// Migration context tracking
private struct MigrationContext
{
    string sourceSystem;
    string sourcePath;
    string outputPath;
    string generatedContent;
    MigrationResult migrationResult;
    bool cancelled;
}

/// Validation result
private struct ValidationResult
{
    bool valid;
    string[] errors;
    string[] warnings;
}

// Import TargetLanguage for type checks
import infrastructure.config.schema.schema : TargetLanguage, TargetType;

