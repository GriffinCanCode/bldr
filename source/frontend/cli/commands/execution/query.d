module frontend.cli.commands.execution.query;

import std.stdio;
import std.string;
import std.algorithm;
import std.array;
import std.conv;
import infrastructure.config.parsing.parser;
import infrastructure.config.schema.schema;
import engine.graph;
import engine.runtime.services;
import frontend.query;
import infrastructure.utils.logging.logger;
import frontend.cli.control.terminal;
import frontend.cli.display.format;
import infrastructure.errors;

/// Query command - executes bldrquery DSL
/// 
/// Supports full Bazel-compatible query language with extensions:
/// - deps(expr), rdeps(expr) - dependency queries
/// - allpaths(from, to), shortest(from, to), somepath(from, to) - path queries
/// - kind(type, expr), attr(name, value, expr) - filtering
/// - Set operations: expr1 + expr2 (union), expr1 & expr2 (intersect), expr1 - expr2 (except)
/// - siblings(expr), buildfiles(pattern) - utility queries
/// - Output formats: --format=pretty|list|json|dot
struct QueryCommand
{
    /// Execute a query with optional format
    static void execute(string queryExpression, string outputFormat = "pretty")
    {
        if (queryExpression.length == 0)
        {
            Logger.error("No query expression provided");
            showQueryHelp();
            return;
        }
        
        // Parse output format
        auto formatResult = parseOutputFormat(outputFormat);
        if (formatResult.isErr)
        {
            Logger.error("Invalid query format");
            Logger.error(formatResult.unwrapErr());
            return;
        }
        auto format = formatResult.unwrap();
        
        // Parse the workspace
        auto configResult = ConfigParser.parseWorkspace(".");
        if (configResult.isErr)
        {
            Logger.error("Failed to parse workspace configuration");
            import infrastructure.errors.formatting.format : errorFormat = format;
            Logger.error(errorFormat(configResult.unwrapErr()));
            return;
        }
        
        auto config = configResult.unwrap();
        
        // Create services and build graph
        auto services = new BuildServices(config, config.options);
        auto graphResult = services.analyzer.analyze("");
        if (graphResult.isErr)
        {
            import infrastructure.errors.formatting.format : errorFormat = format;
            Logger.error("Failed to analyze dependencies");
            Logger.error(errorFormat(graphResult.unwrapErr()));
            return;
        }
        auto graph = graphResult.unwrap();
        
        // Execute query using new bldrquery engine
        auto queryResult = executeQuery(queryExpression, graph);
        if (queryResult.isErr)
        {
            Logger.error("Query error");
            Logger.error(queryResult.unwrapErr());
            showQueryHelp();
            return;
        }
        
        auto results = queryResult.unwrap();
        
        // Format and display results
        auto formatter = QueryFormatter(format);
        auto output = formatter.formatResults(results, queryExpression);
        write(output);
    }
    
    private static void showQueryHelp()
    {
        auto caps = Capabilities.detect();
        auto terminal = Terminal(caps);
        auto formatter = Formatter(caps);
        
        terminal.writeln();
        terminal.writeColored("📊 bldrquery - Build Query Language", Color.Cyan, Style.Bold);
        terminal.writeln();
        terminal.writeln("  Bazel-compatible query language with powerful extensions");
        terminal.writeln();
        
        terminal.writeColored("  Target Patterns:", Color.Magenta, Style.Bold);
        terminal.writeln();
        printQuerySyntax(terminal, "//...", "All targets");
        printQuerySyntax(terminal, "//path/...", "All targets in path");
        printQuerySyntax(terminal, "//path:target", "Specific target");
        printQuerySyntax(terminal, "//path:*", "All targets in directory");
        terminal.writeln();
        
        terminal.writeColored("  Dependency Queries:", Color.Magenta, Style.Bold);
        terminal.writeln();
        printQuerySyntax(terminal, "deps(expr)", "All dependencies (transitive)");
        printQuerySyntax(terminal, "deps(expr, depth)", "Dependencies up to depth");
        printQuerySyntax(terminal, "rdeps(expr)", "Reverse dependencies");
        printQuerySyntax(terminal, "rdeps(expr, depth)", "Reverse deps up to depth");
        terminal.writeln();
        
        terminal.writeColored("  Path Queries:", Color.Magenta, Style.Bold);
        terminal.writeln();
        printQuerySyntax(terminal, "allpaths(from, to)", "All paths between targets");
        printQuerySyntax(terminal, "somepath(from, to)", "Any single path");
        printQuerySyntax(terminal, "shortest(from, to)", "Shortest path (BFS)");
        terminal.writeln();
        
        terminal.writeColored("  Filtering:", Color.Magenta, Style.Bold);
        terminal.writeln();
        printQuerySyntax(terminal, "kind(type, expr)", "Filter by type (executable, library, test)");
        printQuerySyntax(terminal, "attr(name, value, expr)", "Filter by exact attribute match");
        printQuerySyntax(terminal, "filter(attr, regex, expr)", "Filter by regex pattern");
        terminal.writeln();
        
        terminal.writeColored("  Set Operations:", Color.Magenta, Style.Bold);
        terminal.writeln();
        printQuerySyntax(terminal, "expr1 + expr2", "Union (all targets in either)");
        printQuerySyntax(terminal, "expr1 & expr2", "Intersection (targets in both)");
        printQuerySyntax(terminal, "expr1 - expr2", "Except (targets in A but not B)");
        terminal.writeln();
        
        terminal.writeColored("  Utilities:", Color.Magenta, Style.Bold);
        terminal.writeln();
        printQuerySyntax(terminal, "siblings(expr)", "Targets in same directory");
        printQuerySyntax(terminal, "buildfiles(pattern)", "Find Builderfiles");
        printQuerySyntax(terminal, "let(var, val, body)", "Variable binding");
        terminal.writeln();
        
        terminal.writeColored("  Output Formats:", Color.Magenta, Style.Bold);
        terminal.writeln();
        terminal.write("    Use ");
        terminal.writeColored("--format=<type>", Color.Yellow);
        terminal.write(" where type is: ");
        terminal.writeColored("pretty", Color.Green);
        terminal.write(", ");
        terminal.writeColored("list", Color.Green);
        terminal.write(", ");
        terminal.writeColored("json", Color.Green);
        terminal.write(", ");
        terminal.writeColored("dot", Color.Green);
        terminal.writeln();
        terminal.writeln();
        
        terminal.writeColored("  Examples:", Color.Cyan, Style.Bold);
        terminal.writeln();
        terminal.write("    ");
        terminal.writeColored("bldr query", Color.Green);
        terminal.write(" ");
        terminal.writeColored("'deps(//src:app)'", Color.Yellow);
        terminal.writeln();
        
        terminal.write("    ");
        terminal.writeColored("bldr query", Color.Green);
        terminal.write(" ");
        terminal.writeColored("'rdeps(//lib:utils) & kind(test, //...)'", Color.Yellow);
        terminal.writeln();
        
        terminal.write("    ");
        terminal.writeColored("bldr query", Color.Green);
        terminal.write(" ");
        terminal.writeColored("'shortest(//a:x, //b:y)'", Color.Yellow);
        terminal.writeln();
        
        terminal.write("    ");
        terminal.writeColored("bldr query", Color.Green);
        terminal.write(" ");
        terminal.writeColored("'//src/... - //src/test/...'", Color.Yellow);
        terminal.writeln();
        
        terminal.write("    ");
        terminal.writeColored("bldr query", Color.Green);
        terminal.write(" ");
        terminal.writeColored("'filter(\"name\", \".*test.*\", //...)' --format=json", Color.Yellow);
        terminal.writeln();
        terminal.writeln();
        
        terminal.flush();
    }
    
    private static void printQuerySyntax(Terminal terminal, string syntax, string description)
    {
        terminal.write("    ");
        terminal.writeColored(syntax, Color.Green, Style.Bold);
        
        auto padding = 32 - syntax.length;
        if (padding > 0)
        {
            foreach (_; 0 .. padding)
                terminal.write(" ");
        }
        else
        {
            terminal.write("  ");
        }
        
        terminal.writeColored(description, Color.BrightBlack);
        terminal.writeln();
    }
}
