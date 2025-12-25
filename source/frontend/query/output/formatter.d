module frontend.query.output.formatter;

import std.stdio;
import std.algorithm;
import std.array;
import std.conv : to;
import std.json;
import std.string;
import engine.graph;
import infrastructure.config.schema.schema : TargetType;
import frontend.cli.control.terminal : Terminal, Capabilities, Color, Style;
import frontend.cli.display.format : Formatter;
import infrastructure.errors;

/// Output format for query results
enum OutputFormat
{
    Pretty,     // Human-readable with colors
    List,       // Simple list of target names
    JSON,       // Machine-readable JSON
    DOT         // GraphViz DOT format
}

/// Format query results for output
struct QueryFormatter
{
    private OutputFormat format;
    
    this(OutputFormat format) pure nothrow @nogc @safe
    {
        this.format = format;
    }
    
    /// Format results to string
    string formatResults(BuildNode[] results, string query) @system
    {
        final switch (this.format)
        {
            case OutputFormat.Pretty:
                return formatPretty(results, query);
            case OutputFormat.List:
                return formatList(results);
            case OutputFormat.JSON:
                return formatJSON(results, query);
            case OutputFormat.DOT:
                return formatDOT(results);
        }
    }
    
    /// Pretty format with colors
    private string formatPretty(BuildNode[] results, string query) @system
    {
        auto output = appender!string;
        auto caps = Capabilities.detect();
        auto formatter = Formatter(caps);
        
        output ~= "\n";
        
        if (results.empty)
        {
            output ~= formatter.yellow("⚠  ");
            output ~= formatter.bold(formatter.yellow("No Matches Found"));
            output ~= "\n\n";
            output ~= "  Query: ";
            output ~= formatter.dim(query);
            output ~= "\n\n";
            return output.data;
        }
        
        output ~= formatter.green("✨ ");
        output ~= formatter.bold(formatter.green("Query Results"));
        output ~= " ";
        output ~= formatter.dim(std.string.format("(%d target(s))", results.length));
        output ~= "\n\n";
        
        // Sort by target ID for consistent output
        auto sorted = results.sort!((a, b) => a.id < b.id).array;
        
        foreach (i, node; sorted)
        {
            if (node is null)
                continue;
            
            output ~= "  ";
            output ~= formatter.cyan("▸");
            output ~= " ";
            output ~= formatter.bold(node.idString);
            output ~= "\n";
            
            // Show details
            output ~= "    ";
            output ~= formatter.dim("Type: ");
            output ~= formatter.cyan(node.target.type.to!string);
            output ~= "\n";
            
            if (!node.target.sources.empty)
            {
                output ~= "    ";
                output ~= formatter.dim("Sources: ");
                output ~= formatter.yellow(node.target.sources.length.to!string);
                output ~= " file(s)\n";
            }
            
            if (!node.dependencyIds.empty)
            {
                output ~= "    ";
                output ~= formatter.dim("Dependencies: ");
                output ~= formatter.cyan(node.dependencyIds.length.to!string);
                output ~= "\n";
            }
            
            if (!node.dependentIds.empty)
            {
                output ~= "    ";
                output ~= formatter.dim("Dependents: ");
                output ~= formatter.cyan(node.dependentIds.length.to!string);
                output ~= "\n";
            }
            
            if (i < sorted.length - 1)
                output ~= "\n";
        }
        
        output ~= "\n";
        return output.data;
    }
    
    /// Simple list format
    private string formatList(BuildNode[] results) @system
    {
        auto output = appender!string;
        
        // Sort by target ID
        auto sorted = results
            .filter!(n => n !is null)
            .array
            .sort!((a, b) => a.id < b.id)
            .array;
        
        foreach (node; sorted)
            output ~= node.idString ~ "\n";
        
        return output.data;
    }
    
    /// JSON format
    private string formatJSON(BuildNode[] results, string query) @system
    {
        JSONValue root = JSONValue.emptyObject;
        root["query"] = query;
        root["count"] = results.length;
        
        JSONValue[] targets;
        
        foreach (node; results)
        {
            if (node is null)
                continue;
            
            JSONValue target = JSONValue.emptyObject;
            target["id"] = node.idString;
            target["type"] = node.target.type.to!string;
            target["name"] = node.target.name;
            
            // Sources
            JSONValue[] sources;
            foreach (source; node.target.sources)
                sources ~= JSONValue(source);
            target["sources"] = sources;
            
            // Dependencies
            JSONValue[] deps;
            foreach (depId; node.dependencyIds)
                deps ~= JSONValue(depId.toString());
            target["dependencies"] = deps;
            
            // Dependents
            JSONValue[] dependents;
            foreach (depId; node.dependentIds)
                dependents ~= JSONValue(depId.toString());
            target["dependents"] = dependents;
            
            // Language config
            if (!node.target.langConfig.empty)
            {
                JSONValue config = JSONValue.emptyObject;
                foreach (key, value; node.target.langConfig)
                    config[key] = value;
                target["config"] = config;
            }
            
            targets ~= target;
        }
        
        root["targets"] = targets;
        
        return root.toPrettyString();
    }
    
    /// DOT (GraphViz) format
    private string formatDOT(BuildNode[] results) @system
    {
        auto output = appender!string;
        
        output ~= "digraph query_result {\n";
        output ~= "  rankdir=TB;\n";
        output ~= "  node [shape=box, style=rounded];\n";
        output ~= "\n";
        
        // Create a set of nodes in results
        bool[string] nodeSet;
        foreach (node; results)
            if (node !is null)
                nodeSet[node.idString] = true;
        
        // Emit nodes with styling
        foreach (node; results)
        {
            if (node is null)
                continue;
            
            string nodeId = sanitizeDotId(node.idString);
            string label = node.idString;
            string color = getTypeColor(node.target.type);
            
            output ~= std.string.format("  %s [label=\"%s\", color=%s];\n", 
                           nodeId, label, color);
        }
        
        output ~= "\n";
        
        // Emit edges (only if both nodes are in result set)
        foreach (node; results)
        {
            if (node is null)
                continue;
            
            string fromId = sanitizeDotId(node.idString);
            
            foreach (depId; node.dependencyIds)
            {
                string depKey = depId.toString();
                if (depKey in nodeSet)
                {
                    string toId = sanitizeDotId(depKey);
                    output ~= std.string.format("  %s -> %s;\n", fromId, toId);
                }
            }
        }
        
        output ~= "}\n";
        return output.data;
    }
    
    /// Sanitize ID for DOT format
    private string sanitizeDotId(string id) const @safe
    {
        import std.regex : replaceAll, regex;
        
        // Replace special characters with underscores
        string sanitized = id
            .replaceAll(regex(r"[/:.]"), "_")
            .replaceAll(regex(r"^_+"), "node_");
        
        return "\"" ~ sanitized ~ "\"";
    }
    
    /// Get color based on target type
    private string getTypeColor(TargetType type) const pure nothrow @nogc @safe
    {
        final switch (type)
        {
            case TargetType.Executable:
                return "blue";
            case TargetType.Library:
                return "green";
            case TargetType.Test:
                return "orange";
            case TargetType.Custom:
            case TargetType.Shell:
                return "purple";
        }
    }
}

/// Parse output format from string
Result!(OutputFormat, string) parseOutputFormat(string formatStr) @system
{
    switch (formatStr.toLower())
    {
        case "pretty":
        case "default":
            return Result!(OutputFormat, string).ok(OutputFormat.Pretty);
        case "list":
        case "plain":
            return Result!(OutputFormat, string).ok(OutputFormat.List);
        case "json":
            return Result!(OutputFormat, string).ok(OutputFormat.JSON);
        case "dot":
        case "graphviz":
            return Result!(OutputFormat, string).ok(OutputFormat.DOT);
        default:
            return Result!(OutputFormat, string).err(
                std.string.format("Unknown output format: %s (valid: pretty, list, json, dot)", formatStr)
            );
    }
}

