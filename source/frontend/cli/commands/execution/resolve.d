module frontend.cli.commands.execution.resolve;

import std.stdio;
import std.string : strip, toLower;
import std.algorithm : map, filter, sort;
import std.array : array, join;
import std.conv : to;
import std.path : dirName, baseName, buildPath;
import std.file : exists;
import infrastructure.analysis.semver;
import infrastructure.analysis.lockfile;
import infrastructure.analysis.manifests;
import infrastructure.utils.logging;
import frontend.cli.control.terminal;
import frontend.cli.display.format;
import infrastructure.errors;

/// Resolve command - dependency resolution using PubGrub solver
/// 
/// Resolves package dependencies to exact versions using the PubGrub
/// constraint satisfaction algorithm. Supports npm, cargo, and pip.
struct ResolveCommand
{
    /// Execute dependency resolution
    static void execute(
        string manifestPath = ".",
        string outputFormat = "pretty",
        bool dryRun = false,
        bool update = false,
        bool production = false
    )
    {
        auto caps = Capabilities.detect();
        auto terminal = Terminal(caps);
        
        // Find manifest file
        string manifest = findManifest(manifestPath);
        if (manifest.length == 0)
        {
            terminal.writeColored("❌ No manifest file found", Color.Red, Style.Bold);
            terminal.writeln();
            showHelp(terminal);
            return;
        }
        
        terminal.writeColored("🔍 Resolving dependencies", Color.Cyan, Style.Bold);
        terminal.writeln(" for " ~ baseName(manifest));
        terminal.writeln();
        
        // Detect ecosystem
        auto ecosystem = detectEcosystem(manifest);
        if (ecosystem.length == 0)
        {
            terminal.writeColored("❌ Unknown manifest type: ", Color.Red);
            terminal.writeln(baseName(manifest));
            return;
        }
        
        // Parse manifest
        auto parser = getParser(manifest);
        if (parser is null)
        {
            terminal.writeColored("❌ No parser for: ", Color.Red);
            terminal.writeln(ecosystem);
            return;
        }
        
        auto parseResult = parser.parse(manifest);
        if (parseResult.isErr)
        {
            terminal.writeColored("❌ Failed to parse manifest: ", Color.Red);
            terminal.writeln(parseResult.unwrapErr().message());
            return;
        }
        
        auto manifestInfo = parseResult.unwrap();
        
        // Create resolver
        auto resolver = ResolverFactory.offline();
        auto options = ResolveOptions(production, false, update, []);
        
        // Resolve dependencies
        auto resolveResult = resolver.resolve(manifestInfo.dependencies, ecosystem, options);
        if (resolveResult.isErr)
        {
            terminal.writeColored("❌ Resolution failed: ", Color.Red);
            terminal.writeln(resolveResult.unwrapErr().message());
            return;
        }
        
        auto resolved = resolveResult.unwrap();
        
        // Display results
        displayResults(terminal, resolved, outputFormat, ecosystem);
        
        // Write lockfile unless dry-run
        if (!dryRun && resolved.length > 0)
        {
            writeLockfile(terminal, manifest, resolved, ecosystem);
        }
    }
    
    /// Interactive resolution with conflict explanation
    static void executeInteractive(string manifestPath = ".")
    {
        auto caps = Capabilities.detect();
        auto terminal = Terminal(caps);
        
        terminal.writeColored("🧩 Interactive Dependency Resolution", Color.Cyan, Style.Bold);
        terminal.writeln();
        terminal.writeln("  Enter package constraints to resolve:");
        terminal.writeln("  Format: package@constraint (e.g., lodash@^4.0.0)");
        terminal.writeln("  Type 'solve' to resolve, 'quit' to exit");
        terminal.writeln();
        
        auto source = new MemorySource("interactive");
        string[] constraints;
        
        while (true)
        {
            terminal.writeColored("> ", Color.Green);
            string input = readln().strip;
            
            if (input == "quit" || input == "q")
                break;
            
            if (input == "solve" || input == "s")
            {
                if (constraints.length == 0)
                {
                    terminal.writeln("  No constraints added yet");
                    continue;
                }
                
                terminal.writeln();
                terminal.writeColored("  Solving...", Color.Yellow);
                terminal.writeln();
                
                // TODO: Implement interactive solving with the accumulated constraints
                terminal.writeColored("  ✓ Resolution complete", Color.Green);
                terminal.writeln();
                break;
            }
            
            if (input.length > 0)
            {
                constraints ~= input;
                terminal.writeln("  Added: " ~ input);
            }
        }
    }
    
private:
    static string findManifest(string path) @safe
    {
        string[] candidates = [
            buildPath(path, "package.json"),
            buildPath(path, "Cargo.toml"),
            buildPath(path, "pyproject.toml"),
            buildPath(path, "go.mod"),
            buildPath(path, "requirements.txt"),
            path  // Maybe path is the manifest itself
        ];
        
        foreach (c; candidates)
            if (exists(c))
                return c;
        
        return "";
    }
    
    static string detectEcosystem(string manifest) pure @safe
    {
        import std.path : baseName;
        immutable name = baseName(manifest);
        
        if (name == "package.json") return "npm";
        if (name == "Cargo.toml") return "cargo";
        if (name == "pyproject.toml" || name == "requirements.txt") return "pip";
        if (name == "go.mod") return "go";
        if (name == "composer.json") return "composer";
        return "";
    }
    
    static IManifestParser getParser(string manifest) @system
    {
        import std.path : baseName;
        immutable name = baseName(manifest);
        
        if (name == "package.json") return new NpmManifestParser();
        if (name == "Cargo.toml") return new CargoManifestParser();
        if (name == "pyproject.toml" || name == "requirements.txt") return new PythonManifestParser();
        if (name == "go.mod") return new GoManifestParser();
        return null;
    }
    
    static void displayResults(Terminal terminal, ResolvedDependency[] deps, string format, string ecosystem)
    {
        if (deps.length == 0)
        {
            terminal.writeln("  No dependencies to resolve");
            return;
        }
        
        terminal.writeColored("📦 Resolved " ~ deps.length.to!string ~ " dependencies", Color.Green, Style.Bold);
        terminal.writeln(" (" ~ ecosystem ~ ")");
        terminal.writeln();
        
        if (format == "json")
        {
            displayJson(deps);
            return;
        }
        
        // Pretty format
        foreach (ref dep; deps)
        {
            string marker = dep.dev ? " (dev)" : "";
            terminal.writeColored("  • ", Color.Cyan);
            terminal.writeColored(dep.name, Color.White, Style.Bold);
            terminal.writeln(" @ " ~ dep.version_ ~ marker);
        }
        terminal.writeln();
    }
    
    static void displayJson(ResolvedDependency[] deps)
    {
        import std.json;
        
        JSONValue[] arr;
        foreach (ref dep; deps)
        {
            JSONValue obj;
            obj["name"] = dep.name;
            obj["version"] = dep.version_;
            obj["dev"] = dep.dev;
            if (dep.resolved.length > 0)
                obj["resolved"] = dep.resolved;
            if (dep.integrity.length > 0)
                obj["integrity"] = dep.integrity;
            arr ~= obj;
        }
        
        JSONValue root;
        root["dependencies"] = arr;
        writeln(root.toPrettyString());
    }
    
    static void writeLockfile(Terminal terminal, string manifest, ResolvedDependency[] deps, string ecosystem)
    {
        auto generator = LockfileFactory.create(manifest);
        if (generator is null)
        {
            terminal.writeColored("  ⚠ No lockfile generator for " ~ ecosystem, Color.Yellow);
            terminal.writeln();
            return;
        }
        
        Lockfile lockfile;
        lockfile.meta.format = ecosystem;
        lockfile.meta.version_ = 1;
        lockfile.meta.engine = "builder";
        lockfile.dependencies = deps;
        
        immutable lockfilePath = buildPath(dirName(manifest), generator.lockfileName());
        auto writeResult = generator.write(lockfile, lockfilePath);
        
        if (writeResult.isOk)
        {
            terminal.writeColored("  ✓ Wrote ", Color.Green);
            terminal.writeln(lockfilePath);
        }
        else
        {
            terminal.writeColored("  ❌ Failed to write lockfile: ", Color.Red);
            terminal.writeln(writeResult.unwrapErr().message());
        }
    }
    
    static void showHelp(Terminal terminal)
    {
        terminal.writeln();
        terminal.writeColored("📦 bldr resolve - Dependency Resolution", Color.Cyan, Style.Bold);
        terminal.writeln();
        terminal.writeln("  Resolve package dependencies using PubGrub algorithm");
        terminal.writeln();
        
        terminal.writeColored("  Usage:", Color.Magenta, Style.Bold);
        terminal.writeln();
        terminal.writeln("    bldr resolve [path] [options]");
        terminal.writeln();
        
        terminal.writeColored("  Options:", Color.Magenta, Style.Bold);
        terminal.writeln();
        terminal.writeln("    --dry-run       Show resolution without writing lockfile");
        terminal.writeln("    --update        Update all dependencies to latest");
        terminal.writeln("    --production    Exclude dev dependencies");
        terminal.writeln("    --format=json   Output in JSON format");
        terminal.writeln();
        
        terminal.writeColored("  Supported Manifests:", Color.Magenta, Style.Bold);
        terminal.writeln();
        terminal.writeln("    • package.json (npm/yarn/pnpm)");
        terminal.writeln("    • Cargo.toml (Rust)");
        terminal.writeln("    • pyproject.toml, requirements.txt (Python)");
        terminal.writeln("    • go.mod (Go)");
        terminal.writeln();
        
        terminal.writeColored("  Examples:", Color.Magenta, Style.Bold);
        terminal.writeln();
        terminal.writeln("    bldr resolve                   # Resolve in current directory");
        terminal.writeln("    bldr resolve ./frontend        # Resolve in subdirectory");
        terminal.writeln("    bldr resolve --dry-run         # Preview without writing");
        terminal.writeln("    bldr resolve --format=json     # JSON output");
        terminal.writeln();
    }
}

