module frontend.cli.commands.project.migrate;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import infrastructure.migration;
import infrastructure.utils.logging.logger;
import frontend.cli.control.terminal;
import frontend.cli.display.format;
import infrastructure.errors.formatting.format : format;

/// Migration command - convert build files from other build systems
struct MigrateCommand
{
    private static Terminal terminal;
    private static Formatter formatter;
    private static bool initialized = false;
    
    /// Initialize terminal and formatter
    private static void init() @system
    {
        if (!initialized)
        {
            auto caps = Capabilities.detect();
            terminal = Terminal(caps);
            formatter = Formatter(caps);
            initialized = true;
        }
    }
    
    /// Execute migrate command
    static int execute(string[] args) @system
    {
        init();
        
        if (args.length < 2 || args[1] == "--help" || args[1] == "-h")
        {
            showHelp();
            return 0;
        }
        
        string subcommand = args[1];
        
        switch (subcommand)
        {
            case "list":
                listSystems();
                return 0;
                
            case "info":
                if (args.length < 3)
                {
                    Logger.error("Build system name required");
                    Logger.info("Usage: bldr migrate info <system>");
                    return 1;
                }
                showSystemInfo(args[2]);
                return 0;
                
            default:
                // Assume it's --from flag or direct execution
                return performMigration(args[1 .. $]);
        }
    }
    
    private static int performMigration(string[] args) @system
    {
        string fromSystem = "";
        string inputFile = "";
        string outputFile = "Builderfile";
        bool autoDetect = false;
        bool dryRun = false;
        
        // Parse arguments
        for (size_t i = 0; i < args.length; i++)
        {
            if (args[i] == "--from" && i + 1 < args.length)
            {
                fromSystem = args[++i];
            }
            else if (args[i] == "--input" && i + 1 < args.length)
            {
                inputFile = args[++i];
            }
            else if (args[i] == "--output" && i + 1 < args.length)
            {
                outputFile = args[++i];
            }
            else if (args[i] == "--auto" || args[i] == "-a")
            {
                autoDetect = true;
            }
            else if (args[i] == "--dry-run" || args[i] == "-n")
            {
                dryRun = true;
            }
            else if (!args[i].startsWith("--") && inputFile.empty)
            {
                // Treat as input file
                inputFile = args[i];
            }
        }
        
        // Validate inputs
        if (inputFile.empty)
        {
            Logger.error("Input file required");
            Logger.info("Usage: bldr migrate --from=<system> --input=<file> [--output=<file>]");
            Logger.info("   or: bldr migrate --auto <file>");
            return 1;
        }
        
        if (!exists(inputFile))
        {
            Logger.error("Input file does not exist: " ~ inputFile);
            return 1;
        }
        
        // Get migrator
        IMigrator migrator;
        
        if (autoDetect || fromSystem.empty)
        {
            Logger.info("Auto-detecting build system...");
            migrator = MigratorFactory.autoDetect(inputFile);
            
            if (migrator is null)
            {
                Logger.error("Could not auto-detect build system from file: " ~ inputFile);
                Logger.info("Specify explicitly with --from=<system>");
                Logger.info("Available systems: " ~ MigratorFactory.availableSystems().join(", "));
                return 1;
            }
            
            Logger.success("Detected: " ~ migrator.systemName());
        }
        else
        {
            migrator = MigratorFactory.create(fromSystem);
            
            if (migrator is null)
            {
                Logger.error("Unknown build system: " ~ fromSystem);
                Logger.info("Available systems: " ~ MigratorFactory.availableSystems().join(", "));
                Logger.info("Use 'bldr migrate list' to see all supported systems");
                return 1;
            }
        }
        
        // Perform migration
        Logger.info("Migrating from " ~ migrator.systemName() ~ "...");
        Logger.info("Input: " ~ inputFile);
        
        auto result = migrator.migrate(inputFile);
        
        if (result.isErr)
        {
            auto error = result.unwrapErr();
            Logger.error("Migration failed:");
            Logger.error(format(error));
            return 1;
        }
        
        auto migration = result.unwrap();
        
        // Show statistics
        Logger.info("");
        Logger.success("Migration completed!");
        Logger.info("Targets converted: " ~ migration.targets.length.to!string);
        
        if (migration.hasWarnings())
        {
            Logger.warning("Warnings: " ~ migration.warnings.length.to!string);
        }
        
        if (migration.hasErrors())
        {
            Logger.error("Errors: " ~ migration.errors().length.to!string);
        }
        
        // Emit Builderfile
        auto emitter = BuilderfileEmitter();
        string builderfileContent = emitter.emit(migration);
        
        if (dryRun)
        {
            Logger.info("\nDry run - Builderfile content:\n");
            writeln("─────────────────────────────────────────");
            writeln(builderfileContent);
            writeln("─────────────────────────────────────────");
            Logger.info("\nNo files were written (dry run mode)");
        }
        else
        {
            // Write output
            try
            {
                std.file.write(outputFile, builderfileContent);
                Logger.success("Generated: " ~ outputFile);
                Logger.info("");
                Logger.info("Next steps:");
                Logger.info("  1. Review the generated Builderfile");
                Logger.info("  2. Adjust any commented warnings");
                Logger.info("  3. Test with: bldr build");
            }
            catch (Exception e)
            {
                Logger.error("Failed to write output file: " ~ e.msg);
                return 1;
            }
        }
        
        // Show warnings
        if (migration.warnings.length > 0)
        {
            Logger.info("");
            Logger.warning("Migration warnings:");
            
            foreach (warning; migration.warnings)
            {
                string prefix;
                final switch (warning.level)
                {
                    case WarningLevel.Info:
                        prefix = "INFO";
                        break;
                    case WarningLevel.Warning:
                        prefix = "WARN";
                        break;
                    case WarningLevel.Error:
                        prefix = "ERROR";
                        break;
                }
                
                Logger.info("  [" ~ prefix ~ "] " ~ warning.message);
                if (warning.context.length > 0)
                    Logger.info("         Context: " ~ warning.context);
                
                foreach (suggestion; warning.suggestions)
                {
                    Logger.info("         → " ~ suggestion);
                }
            }
        }
        
        return migration.hasErrors() ? 1 : 0;
    }
    
    private static void showHelp() @system
    {
        Logger.info("");
        Logger.info("═══════════════════════════════════════════════════════════");
        Logger.info("  Builder Migration Tool");
        Logger.info("═══════════════════════════════════════════════════════════");
        Logger.info("");
        Logger.info("Convert build files from other build systems to Builderfile format.");
        Logger.info("");
        Logger.info("USAGE:");
        Logger.info("  bldr migrate --from=<system> --input=<file> [--output=<file>]");
        Logger.info("  bldr migrate --auto <file>");
        Logger.info("  bldr migrate list");
        Logger.info("  bldr migrate info <system>");
        Logger.info("");
        Logger.info("OPTIONS:");
        Logger.info("  --from=<system>     Source build system (bazel, cmake, maven, etc.)");
        Logger.info("  --input=<file>      Input build file to migrate");
        Logger.info("  --output=<file>     Output Builderfile (default: Builderfile)");
        Logger.info("  --auto, -a          Auto-detect build system from file");
        Logger.info("  --dry-run, -n       Preview migration without writing files");
        Logger.info("  --help, -h          Show this help message");
        Logger.info("");
        Logger.info("SUBCOMMANDS:");
        Logger.info("  list                List all supported build systems");
        Logger.info("  info <system>       Show details about a specific build system");
        Logger.info("");
        Logger.info("EXAMPLES:");
        Logger.info("  # Auto-detect and migrate");
        Logger.info("  bldr migrate --auto BUILD");
        Logger.info("");
        Logger.info("  # Migrate from Bazel");
        Logger.info("  bldr migrate --from=bazel --input=BUILD --output=Builderfile");
        Logger.info("");
        Logger.info("  # Migrate from CMake");
        Logger.info("  bldr migrate --from=cmake CMakeLists.txt");
        Logger.info("");
        Logger.info("  # Dry run to preview");
        Logger.info("  bldr migrate --auto pom.xml --dry-run");
        Logger.info("");
    }
    
    private static void listSystems() @system
    {
        Logger.info("");
        Logger.info("═══════════════════════════════════════════════════════════");
        Logger.info("  Supported Build Systems");
        Logger.info("═══════════════════════════════════════════════════════════");
        Logger.info("");
        
        auto systems = MigratorFactory.availableSystems().sort().array;
        
        foreach (systemName; systems)
        {
            auto migrator = MigratorFactory.create(systemName);
            if (migrator !is null)
            {
                Logger.info("  " ~ systemName.leftJustify(15) ~ " - " ~ migrator.description());
                Logger.info("    Files: " ~ migrator.defaultFileNames().join(", "));
                Logger.info("");
            }
        }
        
        Logger.info("Use 'bldr migrate info <system>' for detailed information");
        Logger.info("");
    }
    
    private static void showSystemInfo(string systemName) @system
    {
        auto migrator = MigratorFactory.create(systemName);
        
        if (migrator is null)
        {
            Logger.error("Unknown build system: " ~ systemName);
            Logger.info("Use 'bldr migrate list' to see available systems");
            return;
        }
        
        Logger.info("");
        Logger.info("═══════════════════════════════════════════════════════════");
        Logger.info("  " ~ systemName.toUpper() ~ " Migration");
        Logger.info("═══════════════════════════════════════════════════════════");
        Logger.info("");
        Logger.info("Description: " ~ migrator.description());
        Logger.info("");
        Logger.info("Default files: " ~ migrator.defaultFileNames().join(", "));
        Logger.info("");
        
        Logger.info("Supported Features:");
        foreach (feature; migrator.supportedFeatures())
        {
            Logger.info("  ✓ " ~ feature);
        }
        Logger.info("");
        
        Logger.info("Limitations:");
        foreach (limitation; migrator.limitations())
        {
            Logger.info("  ⚠ " ~ limitation);
        }
        Logger.info("");
        
        Logger.info("Example:");
        Logger.info("  bldr migrate --from=" ~ systemName ~ " --input=" ~ 
                   migrator.defaultFileNames()[0]);
        Logger.info("");
    }
}

