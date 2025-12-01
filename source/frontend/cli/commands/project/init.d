module frontend.cli.commands.project.init;

import std.stdio;
import std.path;
import std.string : format;
import std.algorithm;
import std.array : replicate;
import std.range : empty;
import infrastructure.analysis.detection.detector;
import infrastructure.analysis.detection.templates;
import infrastructure.analysis.detection.enhanced;
import infrastructure.analysis.detection.generator;
import infrastructure.utils.logging.logger;
import frontend.cli.control.terminal;
import frontend.cli.display.format;

static import std.file;

/// Initialize command - creates Builderfile and Builderspace
struct InitCommand
{
    private static Terminal terminal;
    private static Formatter formatter;
    
    /// Initialize terminal and formatter
    private static void init()
    {
        auto caps = Capabilities.detect();
        terminal = Terminal(caps);
        formatter = Formatter(caps);
    }
    
    /// Execute the init command
    static void execute(string projectDir = ".")
    {
        init();
        
        terminal.writeln();
        terminal.writeColored("🚀 ", Color.BrightYellow);
        terminal.writeColored("Initializing Builder Project", Color.Cyan, Style.Bold);
        terminal.writeln();
        terminal.writeln();
        
        // Check if files already exist
        immutable builderfilePath = buildPath(projectDir, "Builderfile");
        immutable builderspacePath = buildPath(projectDir, "Builderspace");
        immutable builderignorePath = buildPath(projectDir, ".builderignore");
        
        bool builderfileExists = std.file.exists(builderfilePath);
        bool builderspaceExists = std.file.exists(builderspacePath);
        bool builderignoreExists = std.file.exists(builderignorePath);
        
        if (builderfileExists && builderspaceExists && builderignoreExists)
        {
            terminal.writeColored("⚠️  ", Color.Yellow);
            terminal.writeColored("Project Already Initialized", Color.Yellow, Style.Bold);
            terminal.writeln();
            terminal.writeln();
            terminal.write("  ");
            terminal.writeColored("Builderfile", Color.BrightCyan);
            terminal.write(", ");
            terminal.writeColored("Builderspace", Color.BrightCyan);
            terminal.write(", and ");
            terminal.writeColored(".builderignore", Color.BrightCyan);
            terminal.write(" already exist");
            terminal.writeln();
            terminal.write("  Use ");
            terminal.writeColored("--force", Color.Yellow, Style.Bold);
            terminal.write(" to overwrite existing files");
            terminal.writeln();
            terminal.writeln();
            terminal.flush();
            return;
        }
        
        // Detect project structure with enhanced manifest parsing
        terminal.writeColored("🔍 ", Color.BrightCyan);
        terminal.writeColored("Scanning project directory", Color.Cyan);
        terminal.write("...");
        terminal.writeln();
        terminal.flush();
        
        auto enhancedDetector = new EnhancedProjectDetector(projectDir);
        auto enhanced = enhancedDetector.detectEnhanced();
        auto metadata = enhanced.base;
        
        terminal.writeln();
        
        if (metadata.languages.empty)
        {
            terminal.writeColored("⚠️  ", Color.Yellow);
            terminal.writeColored("No supported languages detected", Color.Yellow, Style.Bold);
            terminal.writeln();
            terminal.write("  Creating generic Builderfile template");
            terminal.writeln();
            terminal.writeln();
        }
        else
        {
            terminal.writeColored("✨ ", Color.Green);
            terminal.writeColored("Detected Languages", Color.Green, Style.Bold);
            terminal.writeln();
            terminal.writeln();
            
            foreach (langInfo; metadata.languages)
            {
                string frameworkInfo = langInfo.framework != ProjectFramework.None ? 
                    format(" [%s]", langInfo.framework) : "";
                    
                terminal.write("  ");
                terminal.writeColored("▸", Color.Magenta);
                terminal.write(" ");
                terminal.writeColored(format("%s", langInfo.language), Color.BrightWhite, Style.Bold);
                terminal.write(" ");
                terminal.writeColored(format("(%.0f%% confidence)", langInfo.confidence * 100), Color.BrightBlack);
                terminal.writeColored(frameworkInfo, Color.BrightCyan);
                terminal.writeln();
                
                if (!langInfo.manifestFiles.empty)
                {
                    foreach (manifest; langInfo.manifestFiles)
                    {
                        terminal.write("    ");
                        terminal.writeColored("→", Color.BrightBlack);
                        terminal.write(" Found: ");
                        terminal.writeColored(baseName(manifest), Color.Cyan);
                        terminal.writeln();
                    }
                }
            }
            terminal.writeln();
        }
        
        // Generate templates (enhanced with manifest data)
        auto generator = new EnhancedTemplateGenerator(metadata, enhanced.manifestInfo);
        
        // Create Builderfile
        if (!builderfileExists)
        {
            string builderfileContent = generator.generateBuilderfile();
            
            try
            {
                std.file.write(builderfilePath, builderfileContent);
                terminal.writeColored("✓", Color.Green);
                terminal.write(" Created ");
                terminal.writeColored("Builderfile", Color.BrightCyan, Style.Bold);
                terminal.writeln();
                
                // Show preview
                showFilePreview("Builderfile", builderfileContent);
            }
            catch (Exception e)
            {
                terminal.writeColored("✗", Color.Red);
                terminal.write(" Failed to create ");
                terminal.writeColored("Builderfile", Color.BrightCyan);
                terminal.write(": ");
                terminal.writeColored(e.msg, Color.Red);
                terminal.writeln();
                terminal.flush();
                return;
            }
        }
        else
        {
            terminal.writeColored("⊙", Color.BrightBlack);
            terminal.write(" Skipping ");
            terminal.writeColored("Builderfile", Color.BrightCyan);
            terminal.write(" (already exists)");
            terminal.writeln();
        }
        
        // Create Builderspace
        if (!builderspaceExists)
        {
            string builderspaceContent = generator.generateBuilderspace();
            
            try
            {
                std.file.write(builderspacePath, builderspaceContent);
                terminal.writeColored("✓", Color.Green);
                terminal.write(" Created ");
                terminal.writeColored("Builderspace", Color.BrightCyan, Style.Bold);
                terminal.writeln();
                
                // Show preview
                showFilePreview("Builderspace", builderspaceContent);
            }
            catch (Exception e)
            {
                terminal.writeColored("✗", Color.Red);
                terminal.write(" Failed to create ");
                terminal.writeColored("Builderspace", Color.BrightCyan);
                terminal.write(": ");
                terminal.writeColored(e.msg, Color.Red);
                terminal.writeln();
                terminal.flush();
                return;
            }
        }
        else
        {
            terminal.writeColored("⊙", Color.BrightBlack);
            terminal.write(" Skipping ");
            terminal.writeColored("Builderspace", Color.BrightCyan);
            terminal.write(" (already exists)");
            terminal.writeln();
        }
        
        // Create .builderignore
        if (!builderignoreExists)
        {
            string builderignoreContent = generateBuilderignore(metadata);
            
            try
            {
                std.file.write(builderignorePath, builderignoreContent);
                terminal.writeColored("✓", Color.Green);
                terminal.write(" Created ");
                terminal.writeColored(".builderignore", Color.BrightCyan, Style.Bold);
                terminal.writeln();
                
                // Show preview
                showFilePreview(".builderignore", builderignoreContent);
            }
            catch (Exception e)
            {
                terminal.writeColored("✗", Color.Red);
                terminal.write(" Failed to create ");
                terminal.writeColored(".builderignore", Color.BrightCyan);
                terminal.write(": ");
                terminal.writeColored(e.msg, Color.Red);
                terminal.writeln();
                terminal.flush();
                return;
            }
        }
        else
        {
            terminal.writeColored("⊙", Color.BrightBlack);
            terminal.write(" Skipping ");
            terminal.writeColored(".builderignore", Color.BrightCyan);
            terminal.write(" (already exists)");
            terminal.writeln();
        }
        
        // Show next steps
        terminal.writeln();
        string[] successBox = [
            "🎉 Initialization Complete!",
            "",
            "Your Builder project is ready to use."
        ];
        terminal.writeln(formatter.formatBox("Success", successBox));
        terminal.writeln();
        
        terminal.writeColored("📋 Next Steps:", Color.Cyan, Style.Bold);
        terminal.writeln();
        terminal.writeln();
        
        terminal.write("  ");
        terminal.writeColored("1.", Color.BrightYellow, Style.Bold);
        terminal.write(" Review and customize your ");
        terminal.writeColored("Builderfile", Color.BrightCyan);
        terminal.writeln();
        
        terminal.write("  ");
        terminal.writeColored("2.", Color.BrightYellow, Style.Bold);
        terminal.write(" Customize ");
        terminal.writeColored(".builderignore", Color.BrightCyan);
        terminal.write(" to exclude specific directories");
        terminal.writeln();
        
        terminal.write("  ");
        terminal.writeColored("3.", Color.BrightYellow, Style.Bold);
        terminal.write(" Run ");
        terminal.writeColored("bldr build", Color.Green, Style.Bold);
        terminal.write(" to build your project");
        terminal.writeln();
        
        terminal.write("  ");
        terminal.writeColored("4.", Color.BrightYellow, Style.Bold);
        terminal.write(" Run ");
        terminal.writeColored("bldr graph", Color.Green, Style.Bold);
        terminal.write(" to visualize dependencies");
        terminal.writeln();
        terminal.writeln();
        
        terminal.flush();
    }
    
    /// Generate .builderignore content based on detected languages
    private static string generateBuilderignore(ProjectMetadata metadata)
    {
        import infrastructure.config.schema.schema : TargetLanguage;
        
        string content = "# Builder Ignore File\n";
        content ~= "# Patterns listed here will be ignored during source scanning and target detection\n";
        content ~= "# Syntax is similar to .gitignore\n\n";
        
        content ~= "# Version control\n";
        content ~= ".git/\n";
        content ~= ".svn/\n";
        content ~= ".hg/\n\n";
        
        content ~= "# Builder's own cache\n";
        content ~= ".builder-cache/\n\n";
        
        // Add language-specific patterns based on detected languages
        bool hasJS = false;
        bool hasPython = false;
        bool hasRuby = false;
        bool hasGo = false;
        bool hasRust = false;
        bool hasJVM = false;
        bool hasDotNet = false;
        bool hasElixir = false;
        bool hasCpp = false;
        
        foreach (langInfo; metadata.languages)
        {
            switch (langInfo.language)
            {
                case TargetLanguage.JavaScript:
                case TargetLanguage.TypeScript:
                    hasJS = true;
                    break;
                case TargetLanguage.Python:
                    hasPython = true;
                    break;
                case TargetLanguage.Ruby:
                    hasRuby = true;
                    break;
                case TargetLanguage.Go:
                    hasGo = true;
                    break;
                case TargetLanguage.Rust:
                    hasRust = true;
                    break;
                case TargetLanguage.Java:
                case TargetLanguage.Kotlin:
                case TargetLanguage.Scala:
                    hasJVM = true;
                    break;
                case TargetLanguage.CSharp:
                case TargetLanguage.FSharp:
                    hasDotNet = true;
                    break;
                case TargetLanguage.Elixir:
                    hasElixir = true;
                    break;
                case TargetLanguage.C:
                case TargetLanguage.Cpp:
                    hasCpp = true;
                    break;
                default:
                    break;
            }
        }
        
        if (hasJS)
        {
            content ~= "# JavaScript/TypeScript dependencies\n";
            content ~= "node_modules/\n";
            content ~= "bower_components/\n";
            content ~= ".npm/\n";
            content ~= ".yarn/\n\n";
        }
        
        if (hasPython)
        {
            content ~= "# Python dependencies and cache\n";
            content ~= "venv/\n";
            content ~= ".venv/\n";
            content ~= "env/\n";
            content ~= "__pycache__/\n";
            content ~= "*.pyc\n";
            content ~= "*.pyo\n";
            content ~= ".pytest_cache/\n";
            content ~= ".mypy_cache/\n\n";
        }
        
        if (hasRuby)
        {
            content ~= "# Ruby dependencies\n";
            content ~= "vendor/bundle/\n";
            content ~= ".bundle/\n\n";
        }
        
        if (hasGo)
        {
            content ~= "# Go dependencies\n";
            content ~= "vendor/\n\n";
        }
        
        if (hasRust)
        {
            content ~= "# Rust build artifacts\n";
            content ~= "target/\n";
            content ~= "Cargo.lock\n\n";
        }
        
        if (hasJVM)
        {
            content ~= "# JVM build artifacts and dependencies\n";
            content ~= "target/\n";
            content ~= "build/\n";
            content ~= ".gradle/\n";
            content ~= ".m2/\n";
            content ~= "*.class\n\n";
        }
        
        if (hasDotNet)
        {
            content ~= "# .NET build artifacts\n";
            content ~= "bin/\n";
            content ~= "obj/\n";
            content ~= "packages/\n";
            content ~= "*.dll\n";
            content ~= "*.exe\n\n";
        }
        
        if (hasElixir)
        {
            content ~= "# Elixir dependencies and build\n";
            content ~= "deps/\n";
            content ~= "_build/\n";
            content ~= ".elixir_ls/\n\n";
        }
        
        if (hasCpp)
        {
            content ~= "# C/C++ build artifacts\n";
            content ~= "build/\n";
            content ~= "cmake-build-*/\n";
            content ~= "*.o\n";
            content ~= "*.obj\n";
            content ~= "*.so\n";
            content ~= "*.dll\n\n";
        }
        
        content ~= "# Common build outputs\n";
        content ~= "dist/\n";
        content ~= "out/\n\n";
        
        content ~= "# IDE directories\n";
        content ~= ".idea/\n";
        content ~= ".vscode/\n";
        content ~= ".vs/\n\n";
        
        content ~= "# OS files\n";
        content ~= ".DS_Store\n";
        content ~= "Thumbs.db\n\n";
        
        content ~= "# Temporary files\n";
        content ~= "tmp/\n";
        content ~= "temp/\n";
        content ~= "*.tmp\n";
        content ~= "*.log\n\n";
        
        content ~= "# Custom patterns\n";
        content ~= "# Add your own patterns below:\n";
        
        return content;
    }
    
    /// Show file preview (first few lines)
    private static void showFilePreview(string filename, string content)
    {
        import std.range : take;
        import std.algorithm : splitter;
        
        terminal.writeln();
        terminal.write("  ");
        terminal.writeColored("📄 Preview: ", Color.BrightBlack);
        terminal.writeColored(filename, Color.BrightCyan);
        terminal.writeln();
        terminal.writeln();
        
        // Top border
        terminal.write("  ");
        terminal.writeColored("╭", Color.BrightBlack);
        foreach (_; 0 .. 68)
            terminal.writeColored("─", Color.BrightBlack);
        terminal.writeColored("╮", Color.BrightBlack);
        terminal.writeln();
        
        auto lines = content.splitter('\n').take(12);
        size_t lineNum = 1;
        foreach (line; lines)
        {
            // Truncate long lines
            if (line.length > 63)
                line = line[0..60] ~ "...";
            
            terminal.write("  ");
            terminal.writeColored("│", Color.BrightBlack);
            terminal.write(" ");
            terminal.writeColored(format("%2d", lineNum), Color.BrightBlack);
            terminal.write(" ");
            terminal.write(line);
            
            // Pad to fixed width
            size_t padding = 63 - line.length;
            foreach (_; 0 .. padding)
                terminal.write(" ");
            
            terminal.write(" ");
            terminal.writeColored("│", Color.BrightBlack);
            terminal.writeln();
            lineNum++;
        }
        
        // Bottom border
        terminal.write("  ");
        terminal.writeColored("╰", Color.BrightBlack);
        foreach (_; 0 .. 68)
            terminal.writeColored("─", Color.BrightBlack);
        terminal.writeColored("╯", Color.BrightBlack);
        terminal.writeln();
        terminal.writeln();
        terminal.flush();
    }
}

