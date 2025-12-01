module frontend.cli.commands.extensions.plugin;

import std.stdio;
import std.algorithm : map, max, reduce;
import std.algorithm.searching : startsWith;
import std.array : array, replicate;
import std.string : leftJustify, rightJustify, strip;
import std.conv : to;
import std.process : execute, executeShell;
import infrastructure.plugins;
import infrastructure.utils.logging.logger;
import infrastructure.errors.formatting.format : formatError = format;
import frontend.cli.control.terminal;
import frontend.cli.display.format;

/// Plugin management command
struct PluginCommand {
    private static Terminal terminal;
    private static Formatter formatter;
    private static PluginRegistry registry;
    private static PluginLoader loader;
    private static bool initialized = false;
    
    /// Initialize terminal, formatter, and plugin system
    private static void init() @system {
        if (!initialized) {
            auto caps = Capabilities.detect();
            terminal = Terminal(caps);
            formatter = Formatter(caps);
            registry = new PluginRegistry("1.0.5");
            loader = new PluginLoader();
            initialized = true;
        }
    }
    
    /// Execute plugin command
    static void execute(string[] args) @system {
        init();
        
        if (args.length < 2) {
            showHelp();
            return;
        }
        
        string subcommand = args[1];
        
        switch (subcommand) {
            case "list":
                listPlugins();
                break;
            case "info":
                if (args.length < 3) {
                    Logger.error("Plugin name required");
                    Logger.info("Usage: bldr plugin info <name>");
                } else {
                    showPluginInfo(args[2]);
                }
                break;
            case "install":
                if (args.length < 3) {
                    Logger.error("Plugin name required");
                    Logger.info("Usage: bldr plugin install <name>");
                } else {
                    installPlugin(args[2]);
                }
                break;
            case "uninstall":
                if (args.length < 3) {
                    Logger.error("Plugin name required");
                    Logger.info("Usage: bldr plugin uninstall <name>");
                } else {
                    uninstallPlugin(args[2]);
                }
                break;
            case "update":
                updatePlugins();
                break;
            case "validate":
                if (args.length < 3) {
                    Logger.error("Plugin name required");
                    Logger.info("Usage: bldr plugin validate <name>");
                } else {
                    validatePlugin(args[2]);
                }
                break;
            case "refresh":
                refreshPlugins();
                break;
            case "create":
                if (args.length < 3) {
                    Logger.error("Plugin name required");
                    Logger.info("Usage: bldr plugin create <name> [--language=d|python|go|rust]");
                } else {
                    string language = "d";
                    if (args.length >= 4 && args[3].startsWith("--language=")) {
                        language = args[3][11 .. $];
                    }
                    createPluginTemplate(args[2], language);
                }
                break;
            default:
                Logger.error("Unknown subcommand: " ~ subcommand);
                showHelp();
        }
        
        terminal.flush();
    }
    
    /// Show help for plugin command
    private static void showHelp() @system {
        terminal.writeln();
        terminal.writeln(formatter.bold("Plugin Management"));
        terminal.writeln();
        terminal.writeln("Usage:");
        terminal.writeln("  bldr plugin <subcommand> [options]");
        terminal.writeln();
        terminal.writeln("Subcommands:");
        terminal.writeln("  " ~ formatter.cyan("list") ~ 
            "                List installed plugins");
        terminal.writeln("  " ~ formatter.cyan("info") ~ 
            " <name>         Show detailed plugin information");
        terminal.writeln("  " ~ formatter.cyan("install") ~ 
            " <name>      Install a plugin via Homebrew");
        terminal.writeln("  " ~ formatter.cyan("uninstall") ~ 
            " <name>    Uninstall a plugin");
        terminal.writeln("  " ~ formatter.cyan("update") ~ 
            "              Update all installed plugins");
        terminal.writeln("  " ~ formatter.cyan("validate") ~ 
            " <name>     Validate plugin installation");
        terminal.writeln("  " ~ formatter.cyan("refresh") ~ 
            "             Refresh plugin cache");
        terminal.writeln("  " ~ formatter.cyan("create") ~ 
            " <name>       Create new plugin from template");
        terminal.writeln();
        terminal.writeln("Examples:");
        terminal.writeln("  bldr plugin list");
        terminal.writeln("  bldr plugin info docker");
        terminal.writeln("  bldr plugin install docker");
        terminal.writeln("  bldr plugin update");
        terminal.writeln("  bldr plugin create myplugin --language=python");
        terminal.writeln();
    }
    
    /// List all installed plugins
    private static void listPlugins() @system {
        terminal.writeln();
        terminal.writeln(formatter.bold("Installed Plugins"));
        terminal.writeln();
        
        auto refreshResult = registry.refresh();
        if (refreshResult.isErr) {
            Logger.error("Failed to refresh plugin registry: " ~ 
                refreshResult.unwrapErr().message);
            return;
        }
        
        auto plugins = registry.list();
        
        if (plugins.length == 0) {
            terminal.writeln("No plugins installed.");
            terminal.writeln();
            terminal.writeln("Install plugins with: " ~ 
                formatter.cyan("brew install builder-plugin-<name>"));
            return;
        }
        
        // Calculate column widths
        int maxNameLen = plugins.map!(p => p.name.length).reduce!max.to!int;
        int maxVerLen = plugins.map!(p => p.version_.length).reduce!max.to!int;
        
        maxNameLen = max(maxNameLen, 4);  // "Name"
        maxVerLen = max(maxVerLen, 7);    // "Version"
        
        // Header
        terminal.writeln(
            formatter.bold(leftJustify("Name", maxNameLen)) ~ "  " ~
            formatter.bold(leftJustify("Version", maxVerLen)) ~ "  " ~
            formatter.bold("Description")
        );
        
        terminal.writeln(
            "-".replicate(maxNameLen) ~ "  " ~
            "-".replicate(maxVerLen) ~ "  " ~
            "-".replicate(40)
        );
        
        // Plugin rows
        foreach (plugin; plugins) {
            terminal.writeln(
                formatter.cyan(leftJustify(plugin.name, maxNameLen)) ~ "  " ~
                leftJustify(plugin.version_, maxVerLen) ~ "  " ~
                plugin.description
            );
        }
        
        terminal.writeln();
        terminal.writeln("Total: " ~ plugins.length.to!string ~ " plugins");
        terminal.writeln();
    }
    
    /// Show detailed plugin information
    private static void showPluginInfo(string name) @system {
        auto getResult = registry.get(name);
        if (getResult.isErr) {
            Logger.error("Failed to get plugin");
            Logger.error(formatError(getResult.unwrapErr()));
            return;
        }
        
        auto plugin = getResult.unwrap();
        
        terminal.writeln();
        terminal.writeln(formatter.bold("Plugin: ") ~ formatter.cyan(plugin.name));
        terminal.writeln();
        terminal.writeln(formatter.bold("Version:       ") ~ plugin.version_);
        terminal.writeln(formatter.bold("Author:        ") ~ plugin.author);
        terminal.writeln(formatter.bold("License:       ") ~ plugin.license);
        terminal.writeln(formatter.bold("Homepage:      ") ~ plugin.homepage);
        terminal.writeln(formatter.bold("Min Builder:   ") ~ plugin.minBuilderVersion);
        terminal.writeln();
        terminal.writeln(formatter.bold("Description:"));
        terminal.writeln("  " ~ plugin.description);
        terminal.writeln();
        terminal.writeln(formatter.bold("Capabilities:"));
        foreach (capability; plugin.capabilities) {
            terminal.writeln("  • " ~ capability);
        }
        terminal.writeln();
    }
    
    /// Install plugin via Homebrew
    private static void installPlugin(string name) @system {
        terminal.writeln();
        terminal.writeln("Installing plugin: " ~ formatter.cyan(name));
        terminal.writeln();
        
        auto formulaName = "builder-plugin-" ~ name;
        auto command = "brew install " ~ formulaName;
        
        terminal.writeln("Running: " ~ formatter.dim(command));
        terminal.writeln();
        
        auto result = executeShell(command);
        
        if (result.status == 0) {
            terminal.writeln();
            terminal.writeln(formatter.green("✓") ~ " Plugin installed successfully");
            terminal.writeln();
            terminal.writeln("Refresh plugin cache...");
            refreshPlugins();
        } else {
            terminal.writeln();
            Logger.error("Installation failed");
            if (result.output.length > 0) {
                terminal.writeln(result.output);
            }
        }
    }
    
    /// Uninstall plugin via Homebrew
    private static void uninstallPlugin(string name) @system {
        terminal.writeln();
        terminal.writeln("Uninstalling plugin: " ~ formatter.cyan(name));
        terminal.writeln();
        
        auto formulaName = "builder-plugin-" ~ name;
        auto command = "brew uninstall " ~ formulaName;
        
        terminal.writeln("Running: " ~ formatter.dim(command));
        terminal.writeln();
        
        auto result = executeShell(command);
        
        if (result.status == 0) {
            terminal.writeln();
            terminal.writeln(formatter.green("✓") ~ " Plugin uninstalled successfully");
            terminal.writeln();
            terminal.writeln("Refresh plugin cache...");
            refreshPlugins();
        } else {
            terminal.writeln();
            Logger.error("Uninstallation failed");
            if (result.output.length > 0) {
                terminal.writeln(result.output);
            }
        }
    }
    
    /// Update all plugins via Homebrew
    private static void updatePlugins() @system {
        terminal.writeln();
        terminal.writeln(formatter.bold("Updating Plugins"));
        terminal.writeln();
        
        auto command = "brew upgrade $(brew list | grep '^builder-plugin-')";
        
        terminal.writeln("Running: " ~ formatter.dim(command));
        terminal.writeln();
        
        auto result = executeShell(command);
        
        if (result.status == 0) {
            terminal.writeln();
            terminal.writeln(formatter.green("✓") ~ " Plugins updated successfully");
            terminal.writeln();
            terminal.writeln("Refresh plugin cache...");
            refreshPlugins();
        } else {
            terminal.writeln();
            terminal.writeln(formatter.yellow("⚠") ~ " No updates available or update failed");
            if (result.output.length > 0) {
                terminal.writeln(result.output);
            }
        }
    }
    
    /// Validate plugin installation
    private static void validatePlugin(string name) @system {
        terminal.writeln();
        terminal.writeln("Validating plugin: " ~ formatter.cyan(name));
        terminal.writeln();
        
        // Check if plugin exists
        auto scanner = new PluginScanner();
        auto findResult = scanner.findPlugin(name);
        
        if (findResult.isErr) {
            terminal.writeln(formatter.red("✗") ~ " Plugin not found");
            Logger.error(formatError(findResult.unwrapErr()));
            return;
        }
        
        terminal.writeln(formatter.green("✓") ~ " Plugin executable found");
        
        auto pluginPath = findResult.unwrap();
        terminal.writeln("  Path: " ~ pluginPath);
        terminal.writeln();
        
        // Query plugin info
        terminal.writeln("Querying plugin info...");
        auto infoResult = loader.queryInfo(name);
        
        if (infoResult.isErr) {
            terminal.writeln(formatter.red("✗") ~ " Failed to query plugin");
            Logger.error(formatError(infoResult.unwrapErr()));
            return;
        }
        
        terminal.writeln(formatter.green("✓") ~ " Plugin responds correctly");
        
        auto info = infoResult.unwrap();
        terminal.writeln("  Name: " ~ info.name);
        terminal.writeln("  Version: " ~ info.version_);
        terminal.writeln();
        
        // Validate plugin info
        auto validator = new PluginValidator("1.0.5");
        auto validateResult = validator.validate(info);
        
        if (validateResult.isErr) {
            terminal.writeln(formatter.red("✗") ~ " Validation failed");
            Logger.error(formatError(validateResult.unwrapErr()));
            return;
        }
        
        terminal.writeln(formatter.green("✓") ~ " Plugin is valid and compatible");
        terminal.writeln();
    }
    
    /// Refresh plugin cache
    private static void refreshPlugins() @system {
        terminal.writeln();
        terminal.writeln("Refreshing plugin cache...");
        
        auto refreshResult = registry.refresh();
        
        if (refreshResult.isErr) {
            Logger.error("Failed to refresh");
            Logger.error(formatError(refreshResult.unwrapErr()));
            return;
        }
        
        auto plugins = registry.list();
        terminal.writeln(formatter.green("✓") ~ " Found " ~ 
            plugins.length.to!string ~ " plugins");
        terminal.writeln();
    }
    
    /// Create plugin template
    private static void createPluginTemplate(string name, string language) @system {
        terminal.writeln();
        terminal.writeln("Creating plugin template: " ~ formatter.cyan(name));
        terminal.writeln("Language: " ~ formatter.yellow(language));
        terminal.writeln();
        
        TemplateLanguage lang;
        switch (language) {
            case "d":
                lang = TemplateLanguage.D;
                break;
            case "python":
                lang = TemplateLanguage.Python;
                break;
            case "go":
                lang = TemplateLanguage.Go;
                break;
            case "rust":
                lang = TemplateLanguage.Rust;
                break;
            default:
                Logger.error("Unknown language: " ~ language);
                Logger.info("Supported languages: d, python, go, rust");
                return;
        }
        
        auto result = TemplateGenerator.create(name, lang);
        
        if (result.isErr) {
            Logger.error("Failed to create template");
            Logger.error(formatError(result.unwrapErr()));
            return;
        }
        
        terminal.writeln(formatter.green("✓") ~ " Plugin template created successfully");
        terminal.writeln();
        terminal.writeln("Next steps:");
        terminal.writeln("  cd builder-plugin-" ~ name);
        terminal.writeln("  # Edit and implement your plugin");
        terminal.writeln("  # Build: see README.md for build instructions");
        terminal.writeln("  # Test: echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"plugin.info\"}' | ./builder-plugin-" ~ name);
        terminal.writeln();
    }
}

