module frontend.cli.commands.project.migrate;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import infrastructure.migration;
import infrastructure.utils.logging;
import frontend.cli.control.terminal;
import frontend.cli.display.format;
import infrastructure.errors.formatting.format : format;
import frontend.cli.commands.project.migration_wizard : MigrationWizard;

/// Migration command - convert build files from other build systems
/// Default: runs interactive wizard. Use --no-wizard for non-interactive mode.
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
        
        // Check for --help
        if (args.canFind("--help") || args.canFind("-h"))
        {
            showHelp();
            return 0;
        }
        
        // Check for --no-wizard flag
        bool noWizard = args.canFind("--no-wizard") || args.canFind("--batch");
        
        // Handle subcommands that don't need wizard
        if (args.length >= 2)
        {
            string subcommand = args[1];
            switch (subcommand)
            {
                case "list":
                    listSystems();
                    return 0;
                    
                case "info":
                    if (args.length < 3)
                    {
                        structuredLog.error("build_system_name_required").emit();
                        structuredLog.info("usage_bldr_migrate_info_system").emit();
                        return 1;
                    }
                    showSystemInfo(args[2]);
                    return 0;
                    
                default:
                    break;
            }
        }
        
        // If --no-wizard or explicit flags provided, use non-interactive mode
        if (noWizard || hasExplicitFlags(args))
        {
            // Filter out wizard-related flags
            auto filteredArgs = args.filter!(a => a != "--no-wizard" && a != "--batch").array;
            if (filteredArgs.length < 2)
            {
                structuredLog.error("input_file_required_for_noninteractive_m").emit();
                structuredLog.info("usage_bldr_migrate_nowizard_auto_file").emit();
                return 1;
            }
            return performMigration(filteredArgs[1 .. $]);
        }
        
        // Default: run the interactive wizard
        structuredLog.debug_("running_migration_wizard_use_help_for_ot").emit();
        int result = MigrationWizard.execute(args);
        
        // If wizard fails with exit 1 and produced no output, show help hint
        if (result != 0)
        {
            structuredLog.info("log_event").emit();
            structuredLog.info("for_noninteractive_migration_try").emit();
            structuredLog.info("__bldr_migrate_auto_buildfile___autodete").emit();
            structuredLog.info("__bldr_migrate_list__________________sho").emit();
            structuredLog.info("__bldr_migrate_help________________show_").emit();
        }
        
        return result;
    }
    
    /// Check if explicit non-wizard flags are provided
    private static bool hasExplicitFlags(string[] args) @safe
    {
        foreach (arg; args)
        {
            if (arg.startsWith("--from") || arg.startsWith("--input") || 
                arg == "--auto" || arg == "-a" || arg == "--dry-run" || arg == "-n")
                return true;
        }
        return false;
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
            structuredLog.error("input_file_required").emit();
            structuredLog.info("usage_bldr_migrate_fromsystem_inputfile_").emit();
            structuredLog.info("___or_bldr_migrate_auto_file").emit();
            return 1;
        }
        
        if (!exists(inputFile))
        {
            structuredLog.error("input_file_does_not_exist_").field("detail", "Input file does not exist: " ~ inputFile).emit();
            return 1;
        }
        
        // Get migrator
        IMigrator migrator;
        
        if (autoDetect || fromSystem.empty)
        {
            structuredLog.info("autodetecting_build_system").emit();
            migrator = MigratorFactory.autoDetect(inputFile);
            
            if (migrator is null)
            {
                structuredLog.error("could_not_autodetect_build_system_from_f").field("detail", "Could not auto-detect build system from file: " ~ inputFile).emit();
                structuredLog.info("specify_explicitly_with_fromsystem").emit();
                structuredLog.info("available_systems_").field("detail", "Available systems: " ~ MigratorFactory.availableSystems().join(", ")).emit();
                return 1;
            }
            
            structuredLog.info("detected_").field("detail", "Detected: " ~ migrator.systemName()).emit();
        }
        else
        {
            migrator = MigratorFactory.create(fromSystem);
            
            if (migrator is null)
            {
                structuredLog.error("unknown_build_system_").field("detail", "Unknown build system: " ~ fromSystem).emit();
                structuredLog.info("available_systems_").field("detail", "Available systems: " ~ MigratorFactory.availableSystems().join(", ")).emit();
                structuredLog.info("use_bldr_migrate_list_to_see_all_support").emit();
                return 1;
            }
        }
        
        // Perform migration
        structuredLog.info("migrating_from_").field("detail", "Migrating from " ~ migrator.systemName() ~ "...").emit();
        structuredLog.info("input_").field("detail", "Input: " ~ inputFile).emit();
        
        auto result = migrator.migrate(inputFile);
        
        if (result.isErr)
        {
            auto error = result.unwrapErr();
            structuredLog.error("migration_failed").emit();
            structuredLog.error("log_event").field("message", format(error)).emit();
            return 1;
        }
        
        auto migration = result.unwrap();
        
        // Show statistics
        structuredLog.info("log_event").emit();
        structuredLog.info("migration_completed").emit();
        structuredLog.info("targets_converted_").field("detail", "Targets converted: " ~ migration.targets.length.to!string).emit();
        
        if (migration.hasWarnings())
        {
            structuredLog.warning("warnings_").field("detail", "Warnings: " ~ migration.warnings.length.to!string).emit();
        }
        
        if (migration.hasErrors())
        {
            structuredLog.error("errors_").field("detail", "Errors: " ~ migration.errors().length.to!string).emit();
        }
        
        // Emit Builderfile
        auto emitter = BuilderfileEmitter();
        string builderfileContent = emitter.emit(migration);
        
        if (dryRun)
        {
            structuredLog.info("ndry_run__builderfile_contentn").emit();
            writeln("─────────────────────────────────────────");
            writeln(builderfileContent);
            writeln("─────────────────────────────────────────");
            structuredLog.info("nno_files_were_written_dry_run_mode").emit();
        }
        else
        {
            // Write output
            try
            {
                std.file.write(outputFile, builderfileContent);
                structuredLog.info("generated_").field("detail", "Generated: " ~ outputFile).emit();
                structuredLog.info("log_event").emit();
                structuredLog.info("next_steps").emit();
                structuredLog.info("__1_review_the_generated_builderfile").emit();
                structuredLog.info("__2_adjust_any_commented_warnings").emit();
                structuredLog.info("__3_test_with_bldr_build").emit();
            }
            catch (Exception e)
            {
                structuredLog.error("failed_to_write_output_file_").field("detail", "Failed to write output file: " ~ e.msg).emit();
                return 1;
            }
        }
        
        // Show warnings
        if (migration.warnings.length > 0)
        {
            structuredLog.info("log_event").emit();
            structuredLog.warning("migration_warnings").emit();
            
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
                
                structuredLog.info("__").field("detail", "  [" ~ prefix ~ "] " ~ warning.message).emit();
                if (warning.context.length > 0)
                    structuredLog.info("_________context_").field("detail", "         Context: " ~ warning.context).emit();
                
                foreach (suggestion; warning.suggestions)
                {
                    structuredLog.info("__________").field("detail", "         → " ~ suggestion).emit();
                }
            }
        }
        
        return migration.hasErrors() ? 1 : 0;
    }
    
    private static void showHelp() @system
    {
        structuredLog.info("log_event").emit();
        structuredLog.info("log_event").emit();
        structuredLog.info("__builder_migration_tool").emit();
        structuredLog.info("log_event").emit();
        structuredLog.info("log_event").emit();
        structuredLog.info("convert_build_files_from_other_build_sys").emit();
        structuredLog.info("log_event").emit();
        structuredLog.info("usage").emit();
        structuredLog.info("__bldr_migrate_________________interacti").emit();
        structuredLog.info("__bldr_migrate_nowizard_____noninteracti").emit();
        structuredLog.info("__bldr_migrate_auto_file___autodetect_an").emit();
        structuredLog.info("__bldr_migrate_list____________list_supp").emit();
        structuredLog.info("__bldr_migrate_info_system___show_build_").emit();
        structuredLog.info("log_event").emit();
        structuredLog.info("options").emit();
        structuredLog.info("__nowizard_________skip_wizard_use_nonin").emit();
        structuredLog.info("__fromsystem_____source_build_system_baz").emit();
        structuredLog.info("__inputfile______input_build_file_to_mig").emit();
        structuredLog.info("__outputfile_____output_builderfile_defa").emit();
        structuredLog.info("__auto_a__________autodetect_build_syste").emit();
        structuredLog.info("__dryrun_n_______preview_migration_witho").emit();
        structuredLog.info("__help_h__________show_this_help_message").emit();
        structuredLog.info("log_event").emit();
        structuredLog.info("subcommands").emit();
        structuredLog.info("__list________________list_all_supported").emit();
        structuredLog.info("__info_system_______show_details_about_a").emit();
        structuredLog.info("log_event").emit();
        structuredLog.info("examples").emit();
        structuredLog.info("___interactive_wizard_recommended").emit();
        structuredLog.info("__bldr_migrate").emit();
        structuredLog.info("log_event").emit();
        structuredLog.info("___autodetect_and_migrate_noninteractive").emit();
        structuredLog.info("__bldr_migrate_auto_build").emit();
        structuredLog.info("log_event").emit();
        structuredLog.info("___explicit_noninteractive_migration").emit();
        structuredLog.info("__bldr_migrate_nowizard_fromcmake_cmakel").emit();
        structuredLog.info("log_event").emit();
        structuredLog.info("___dry_run_to_preview").emit();
        structuredLog.info("__bldr_migrate_auto_pomxml_dryrun").emit();
        structuredLog.info("log_event").emit();
    }
    
    private static void listSystems() @system
    {
        structuredLog.info("log_event").emit();
        structuredLog.info("log_event").emit();
        structuredLog.info("__supported_build_systems").emit();
        structuredLog.info("log_event").emit();
        structuredLog.info("log_event").emit();
        
        auto systems = MigratorFactory.availableSystems().sort().array;
        
        foreach (systemName; systems)
        {
            auto migrator = MigratorFactory.create(systemName);
            if (migrator !is null)
            {
                structuredLog.info("__").field("detail", "  " ~ systemName.leftJustify(15) ~ " - " ~ migrator.description()).emit();
                structuredLog.info("____files_").field("detail", "    Files: " ~ migrator.defaultFileNames().join(", ")).emit();
                structuredLog.info("log_event").emit();
            }
        }
        
        structuredLog.info("use_bldr_migrate_info_system_for_detaile").emit();
        structuredLog.info("log_event").emit();
    }
    
    private static void showSystemInfo(string systemName) @system
    {
        auto migrator = MigratorFactory.create(systemName);
        
        if (migrator is null)
        {
            structuredLog.error("unknown_build_system_").field("detail", "Unknown build system: " ~ systemName).emit();
            structuredLog.info("use_bldr_migrate_list_to_see_available_s").emit();
            return;
        }
        
        structuredLog.info("log_event").emit();
        structuredLog.info("log_event").emit();
        structuredLog.info("__").field("detail", "  " ~ systemName.toUpper() ~ " Migration").emit();
        structuredLog.info("log_event").emit();
        structuredLog.info("log_event").emit();
        structuredLog.info("description_").field("detail", "Description: " ~ migrator.description()).emit();
        structuredLog.info("log_event").emit();
        structuredLog.info("default_files_").field("detail", "Default files: " ~ migrator.defaultFileNames().join(", ")).emit();
        structuredLog.info("log_event").emit();
        
        structuredLog.info("supported_features").emit();
        foreach (feature; migrator.supportedFeatures())
        {
            structuredLog.info("___").field("detail", "  ✓ " ~ feature).emit();
        }
        structuredLog.info("log_event").emit();
        
        structuredLog.info("limitations").emit();
        foreach (limitation; migrator.limitations())
        {
            structuredLog.info("___").field("detail", "  ⚠ " ~ limitation).emit();
        }
        structuredLog.info("log_event").emit();
        
        structuredLog.info("example").emit();
        structuredLog.info("__bldr_migrate_from").field("detail", "  bldr migrate --from=" ~ systemName ~ " --input=" ~ 
                   migrator.defaultFileNames()[0]).emit();
        structuredLog.info("log_event").emit();
    }
}

