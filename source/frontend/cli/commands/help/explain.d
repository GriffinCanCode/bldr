module frontend.cli.commands.help.explain;

import std.stdio;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.conv;
import std.json;
import infrastructure.utils.logging;
import frontend.cli.display.format;
import frontend.cli.control.terminal;

/// Explain command - AI-optimized documentation system
/// Provides instant, queryable documentation for AI assistants
struct ExplainCommand
{
    /// Execute explain command with subcommands
    static void execute(string[] args) @system
    {
        if (args.length < 2)
        {
            showUsage();
            return;
        }
        
        const subcommand = args[1];
        
        switch (subcommand)
        {
            case "list":
                listTopics();
                break;
            
            case "search":
                if (args.length < 3)
                {
                    structuredLog.error("usage_bldr_explain_search_query").emit();
                    return;
                }
                performSearch(args[2 .. $].join(" "));
                break;
            
            case "example":
                if (args.length < 3)
                {
                    structuredLog.error("usage_bldr_explain_example_topic").emit();
                    return;
                }
                showExamples(args[2]);
                break;
            
            case "workflow":
                if (args.length < 3)
                {
                    structuredLog.error("usage_bldr_explain_workflow_workflowname").emit();
                    return;
                }
                showWorkflow(args[2]);
                break;
            
            default:
                // Smart lookup: check for exact topic match, otherwise search
                string query = args[1 .. $].join(" ");
                smartLookup(query);
                break;
        }
    }
    
    /// Show usage information
    private static void showUsage() @system
    {
        writeln();
        writeln("=== Builder Explain - AI-Optimized Documentation ===");
        writeln();
        writeln("USAGE:");
        writeln("  bldr explain <topic>              Show topic documentation (smart match)");
        writeln("  bldr explain list                 List all available topics");
        writeln("  bldr explain search <query>       Search across all topics");
        writeln("  bldr explain example <topic>      Show working examples");
        writeln("  bldr explain workflow <name>      Show step-by-step workflow");
        writeln();
        writeln("AVAILABLE TOPICS:");
        writeln("  blake3           BLAKE3 hash function - 3-5x faster than SHA-256");
        writeln("  caching          Multi-tier caching: target, action, remote");
        writeln("  determinism      Bit-for-bit reproducible builds");
        writeln("  incremental      Module-level incremental compilation");
        writeln("  action-cache     Fine-grained action caching");
        writeln("  remote-cache     Distributed cache for teams/CI");
        writeln("  provenance       SLSA-compliant build provenance for supply chain security");
        writeln("  hermetic         Isolated sandboxed build environments");
        writeln();
        writeln("EXAMPLES:");
        writeln("  bldr explain blake3");
        writeln("  bldr explain \"fast builds\"");
        writeln("  bldr explain example caching");
        writeln();
    }
    
    /// List all available topics
    private static void listTopics() @system
    {
        auto indexPath = buildPath(getDocsPath(), "ai", "index.yaml");
        
        if (!exists(indexPath))
        {
            structuredLog.error("ai_documentation_index_not_found_at_").field("detail", "AI documentation index not found at: " ~ indexPath).emit();
            return;
        }
        
        try
        {
            auto index = parseYAMLIndex(indexPath);
            
            writeln();
            writeln("=== Available Topics ===");
            writeln();
            
            if ("concepts" in index && index["concepts"].type == JSONType.object)
            {
                // Group by category if possible
                // For now, just list them
                string[][string] categories;
                string[] uncategorized;
                
                foreach (topic, data; index["concepts"].object)
                {
                    if (data.type != JSONType.object) continue;
                    
                    string summary = "summary" in data ? data["summary"].str : "";
                    
                    // We could look up category in the file, but that's slow.
                    // For now just print alphabetical list
                    writefln("  \x1b[36m%-25s\x1b[0m %s", topic, summary);
                }
                writeln();
            }
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_read_index_").field("detail", "Failed to read index: " ~ e.msg).emit();
        }
    }

    /// Smart lookup that handles exact matches and fuzzy search
    private static void smartLookup(string query) @system
    {
        // 1. Try exact match (or alias)
        string topic = resolveAlias(query);
        string topicPath = getTopicPath(topic);
        
        if (topicPath.length > 0 && exists(topicPath))
        {
            displayTopicFromFile(topicPath);
            return;
        }
        
        // 2. Fallback to search
        auto matches = findMatches(query);
        
        if (matches.length == 1)
        {
            // Only one match - show it directly
            string matchTopic = matches[0]["topic"].str;
            writeln("Best match for '" ~ query ~ "': " ~ matchTopic);
            
            topicPath = getTopicPath(matchTopic);
            if (topicPath.length > 0 && exists(topicPath))
            {
                displayTopicFromFile(topicPath);
            }
            else 
            {
                structuredLog.error("topic_found_in_index_but_file_missing_").field("detail", "Topic found in index but file missing: " ~ matchTopic).emit();
            }
        }
        else if (matches.length > 1)
        {
            // Multiple matches - list them
            writeln("Topic '" ~ query ~ "' not found. Did you mean:");
            writeln();
            foreach (match; matches)
            {
                writefln("  \x1b[36m%-20s\x1b[0m %s", match["topic"].str, match["summary"].str);
            }
            writeln();
            writefln("Found %d related topics. Use 'bldr explain <topic>' to view.", matches.length);
        }
        else
        {
            structuredLog.error("topic_not_found_").field("detail", "Topic not found: " ~ query).emit();
            writeln("\nAvailable topics:");
            writeln("  bldr explain list");
        }
    }
    
    /// Perform search and display results
    private static void performSearch(string query) @system
    {
        auto matches = findMatches(query);
        
        writeln();
        if (matches.length == 0)
        {
            structuredLog.info("no_topics_found_matching_").field("detail", "No topics found matching: " ~ query).emit();
            writeln("\nTry: bldr explain list");
        }
        else
        {
            writeln("=== Search Results for: " ~ query ~ " ===");
            writeln();
            foreach (match; matches)
            {
                writefln("  \x1b[36m%-20s\x1b[0m %s", match["topic"].str, match["summary"].str);
            }
            writeln();
            writefln("Found %d topic(s). Use 'bldr explain <topic>' for details.", matches.length);
        }
    }
    
    /// Find matching topics
    private static JSONValue[] findMatches(string query) @system
    {
        auto indexPath = buildPath(getDocsPath(), "ai", "index.yaml");
        JSONValue[] matches;
        
        if (!exists(indexPath)) return matches;
        
        try
        {
            auto index = parseYAMLIndex(indexPath);
            auto queryLower = query.toLower();
            // Normalize query (replace separators with spaces)
            auto normalizedQuery = queryLower.replace("-", " ").replace("_", " ");
            auto queryTokens = normalizedQuery.split(" ");
            
            if ("concepts" in index && index["concepts"].type == JSONType.object)
            {
                foreach (topic, data; index["concepts"].object)
                {
                    if (data.type != JSONType.object) continue;
                    
                    string topicLower = topic.toLower();
                    string normalizedTopic = topicLower.replace("-", " ").replace("_", " ");
                    string summaryLower = "summary" in data ? data["summary"].str.toLower() : "";
                    
                    // Match 1: Topic contains query (fuzzy on separators)
                    bool match = normalizedTopic.canFind(normalizedQuery);
                    
                    // Match 2: All query tokens present in topic
                    if (!match && queryTokens.length > 1)
                    {
                        bool allTokens = true;
                        foreach (token; queryTokens)
                        {
                            if (!normalizedTopic.canFind(token))
                            {
                                allTokens = false;
                                break;
                            }
                        }
                        if (allTokens) match = true;
                    }
                    
                    // Match 3: Summary contains query
                    if (!match && summaryLower.length > 0)
                        match = summaryLower.canFind(queryLower);
                    
                    // Match 4: Keywords
                    if (!match && "keywords" in data && data["keywords"].type == JSONType.array)
                    {
                        foreach (keyword; data["keywords"].array)
                            if (keyword.str.toLower().canFind(queryLower))
                            {
                                match = true;
                                break;
                            }
                    }
                    
                    if (match)
                    {
                        auto matchData = data.object.dup;
                        matchData["topic"] = topic;
                        matches ~= JSONValue(matchData);
                    }
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.error("search_failed_").field("detail", "Search failed: " ~ e.msg).emit();
        }
        
        return matches;
    }
    
    /// Get path for a topic
    private static string getTopicPath(string topic) @system
    {
        string topicPath;
        auto indexPath = buildPath(getDocsPath(), "ai", "index.yaml");
        
        try
        {
            if (exists(indexPath))
            {
                auto index = parseYAMLIndex(indexPath);
                if ("concepts" in index && topic in index["concepts"].object)
                {
                    auto entry = index["concepts"][topic];
                    if ("file" in entry)
                        topicPath = buildPath(getDocsPath(), "ai", entry["file"].str);
                }
            }
        }
        catch (Exception e) {}
        
        if (topicPath.length == 0)
            topicPath = buildPath(getDocsPath(), "ai", "concepts", topic ~ ".yaml");
            
        return topicPath;
    }
    
    /// Display topic from file
    private static void displayTopicFromFile(string path) @system
    {
        try
        {
            auto content = readText(path);
            auto doc = parseSimpleYAML(content);
            displayTopic(doc);
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_read_topic_").field("detail", "Failed to read topic: " ~ e.msg).emit();
        }
    }
    
    /// Show topic documentation (Legacy/Direct wrapper)
    private static void showTopic(string topic) @system
    {
        smartLookup(topic);
    }
    
    /// Show examples for a topic
    private static void showExamples(string topic) @system
    {
        topic = resolveAlias(topic);
        string topicPath = getTopicPath(topic);
        
        if (topicPath.length == 0 || !exists(topicPath))
        {
            structuredLog.error("topic_not_found_").field("detail", "Topic not found: " ~ topic).emit();
            return;
        }
        
        try
        {
            auto content = readText(topicPath);
            auto doc = parseSimpleYAML(content);
            
            displayExamples(doc);
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_read_examples_").field("detail", "Failed to read examples: " ~ e.msg).emit();
        }
    }
    
    /// Show workflow documentation
    private static void showWorkflow(string workflow) @system
    {
        structuredLog.info("workflows_not_yet_implemented_coming_soo").emit();
        writeln("\nCurrently available: bldr explain <topic>");
    }
    
    /// Display topic documentation
    private static void displayTopic(JSONValue doc) @system
    {
        writeln();
        
        if ("topic" in doc)
        {
            writeln("=== " ~ doc["topic"].str.toUpper() ~ " ===");
            writeln();
        }
        
        if ("summary" in doc)
        {
            writeln("\x1b[1mSUMMARY:\x1b[0m");
            writeln("  " ~ doc["summary"].str);
            writeln();
        }
        
        if ("definition" in doc)
        {
            writeln("\x1b[1mDEFINITION:\x1b[0m");
            foreach (line; doc["definition"].str.split("\n"))
                if (line.strip().length > 0)
                    writeln("  " ~ line.strip());
            writeln();
        }
        
        if ("key_points" in doc && doc["key_points"].type == JSONType.array)
        {
            writeln("\x1b[1mKEY POINTS:\x1b[0m");
            foreach (point; doc["key_points"].array)
                writeln("  • " ~ point.str);
            writeln();
        }
        
        if ("usage_examples" in doc && doc["usage_examples"].type == JSONType.array)
        {
            writeln("\x1b[1mUSAGE:\x1b[0m");
            foreach (example; doc["usage_examples"].array)
            {
                if (example.type == JSONType.object)
                {
                    if ("description" in example)
                        writeln("  " ~ example["description"].str ~ ":");
                    if ("code" in example)
                    {
                        foreach (line; example["code"].str.split("\n"))
                            if (line.strip().length > 0)
                                writeln("    " ~ line);
                        writeln();
                    }
                }
            }
        }
        
        if ("related" in doc && doc["related"].type == JSONType.array)
        {
            writeln("\x1b[1mRELATED:\x1b[0m");
            auto related = doc["related"].array.map!(r => r.str).array;
            writeln("  " ~ related.join(", "));
            writeln();
        }
        
        if ("next_steps" in doc)
        {
            writeln("\x1b[1mNEXT STEPS:\x1b[0m");
            foreach (line; doc["next_steps"].str.split("\n"))
                if (line.strip().length > 0)
                    writeln("  " ~ line.strip());
            writeln();
        }
    }
    
    /// Display examples section
    private static void displayExamples(JSONValue doc) @system
    {
        writeln();
        
        if ("topic" in doc)
        {
            writeln("=== Examples: " ~ doc["topic"].str ~ " ===");
            writeln();
        }
        
        if ("usage_examples" in doc && doc["usage_examples"].type == JSONType.array)
        {
            foreach (i, example; doc["usage_examples"].array)
            {
                if (example.type == JSONType.object)
                {
                    writefln("\x1b[1mEXAMPLE %d:\x1b[0m", i + 1);
                    if ("description" in example)
                        writeln("  " ~ example["description"].str);
                    if ("command" in example)
                        writeln("  Command: \x1b[32m" ~ example["command"].str ~ "\x1b[0m");
                    if ("code" in example)
                    {
                        writeln("  Code:");
                        foreach (line; example["code"].str.split("\n"))
                            if (line.strip().length > 0)
                                writeln("    " ~ line);
                    }
                    writeln();
                }
            }
        }
        else
        {
            structuredLog.info("no_examples_available_for_this_topic").emit();
        }
    }
    
    /// Resolve topic alias
    private static string resolveAlias(string topic) @system
    {
        auto indexPath = buildPath(getDocsPath(), "ai", "index.yaml");
        
        if (!exists(indexPath))
            return topic;
        
        try
        {
            auto index = parseYAMLIndex(indexPath);
            
            if ("aliases" in index && index["aliases"].type == JSONType.object)
            {
                if (topic in index["aliases"].object)
                    return index["aliases"][topic].str;
            }
        }
        catch (Exception e)
        {
            // Ignore and return original topic
        }
        
        return topic;
    }
    
    /// Get documentation path
    private static string getDocsPath() @system
    {
        // Look for docs relative to current directory or workspace root
        if (exists("docs"))
            return "docs";
        
        // Try parent directories
        string current = getcwd();
        while (current.length > 1)
        {
            auto docsPath = buildPath(current, "docs");
            if (exists(docsPath))
                return docsPath;
            
            auto parent = dirName(current);
            if (parent == current)
                break;
            current = parent;
        }
        
        return "docs"; // Fallback
    }
    
    /// Parse YAML index file (simple implementation)
    private static JSONValue parseYAMLIndex(string path) @system
    {
        auto content = readText(path);
        return parseSimpleYAML(content);
    }
    
    /// Simple YAML parser for our specific format
    /// Handles nested sections, arrays, multiline strings, and key-value pairs
    private static JSONValue parseSimpleYAML(string content) @system
    {
        JSONValue result;
        result.object = null;
        
        string[] lines = content.split("\n");
        
        // Track section navigation with (section_ptr, indent_level) pairs
        struct StackEntry { JSONValue* section; int indent; }
        StackEntry[] stack = [StackEntry(&result, -1)];
        
        string currentMultilineKey = null;
        int multilineIndent = -1;
        JSONValue* multilineTarget = null;
        
        foreach (line; lines)
        {
            auto stripped = line.strip();
            if (stripped.length == 0 || stripped.startsWith("#"))
            {
                // Append newline to multiline if active
                if (currentMultilineKey !is null && multilineTarget !is null)
                {
                    if (currentMultilineKey in (*multilineTarget).object &&
                        (*multilineTarget)[currentMultilineKey].type == JSONType.string)
                    {
                        string cur = (*multilineTarget)[currentMultilineKey].str;
                        (*multilineTarget).object[currentMultilineKey] = JSONValue(cur ~ "\n");
                    }
                }
                continue;
            }
            
            auto indent = cast(int)(line.length - line.stripLeft().length);
            
            // Handle multiline string continuation
            if (currentMultilineKey !is null && multilineIndent != -1 && indent > multilineIndent)
            {
                if (multilineTarget !is null && currentMultilineKey in (*multilineTarget).object)
                {
                    string cur = (*multilineTarget)[currentMultilineKey].str;
                    (*multilineTarget).object[currentMultilineKey] = JSONValue(cur ~ stripped ~ "\n");
                }
                continue;
            }
            else if (currentMultilineKey !is null)
            {
                // End multiline mode
                currentMultilineKey = null;
                multilineIndent = -1;
                multilineTarget = null;
            }
            
            // Pop stack to correct indent level (but don't pop past array containers)
            while (stack.length > 1 && indent <= stack[$ - 1].indent)
            {
                // If this is an array item, don't pop past the array's parent
                if (stripped.startsWith("- ") && indent == stack[$ - 1].indent)
                    break;
                stack = stack[0 .. $ - 1];
            }
            
            auto currentSection = stack[$ - 1].section;
            
            if (stripped.endsWith(":") && !stripped.canFind(": "))
            {
                // New section (no value after colon)
                // Ensure current section is an object first
                if ((*currentSection).type != JSONType.object && 
                    (*currentSection).type != JSONType.array)
                    (*currentSection).object = null;
                    
                auto key = stripped[0 .. $ - 1].strip();
                if ((*currentSection).type == JSONType.object)
                {
                    (*currentSection).object[key] = JSONValue();
                    (*currentSection)[key].object = null;
                    stack ~= StackEntry(&(*currentSection)[key], indent);
                }
            }
            else if (stripped.startsWith("- "))
            {
                // Array item
                auto valueStr = stripped[2 .. $].strip();
                
                // Ensure we're working with an array
                if ((*currentSection).type != JSONType.array)
                    (*currentSection).array = null;
                
                // Check for key: value in array item (object start)
                long colonIdx = findUnquotedColon(valueStr);
                
                if (colonIdx > 0)
                {
                    auto key = valueStr[0 .. colonIdx].strip();
                    auto val = valueStr[colonIdx + 1 .. $].strip();
                    if (val.startsWith("\"") && val.endsWith("\"") && val.length > 1)
                        val = val[1 .. $ - 1];
                    
                    // Handle multiline value in array object
                    if (val == "|")
                    {
                        JSONValue obj;
                        obj.object = null;
                        obj.object[key] = JSONValue("");
                        (*currentSection).array ~= obj;
                        currentMultilineKey = key;
                        multilineIndent = indent;
                        multilineTarget = &(*currentSection).array[$ - 1];
                    }
                    else
                    {
                        JSONValue obj;
                        obj.object = null;
                        obj.object[key] = JSONValue(val);
                        (*currentSection).array ~= obj;
                        // Push to stack so subsequent keys at deeper indent add to this object
                        stack ~= StackEntry(&(*currentSection).array[$ - 1], indent);
                    }
                }
                else
                {
                    // Plain array item (string)
                    if (valueStr.startsWith("\"") && valueStr.endsWith("\"") && valueStr.length > 1)
                        valueStr = valueStr[1 .. $ - 1];
                    (*currentSection).array ~= JSONValue(valueStr);
                }
            }
            else if (stripped.canFind(": "))
            {
                // Key: value pair
                long colonIdx = findUnquotedColon(stripped);
                if (colonIdx > 0)
                {
                    auto key = stripped[0 .. colonIdx].strip();
                    auto value = stripped[colonIdx + 1 .. $].strip();
                    
                    // Multiline string
                    if (value == "|")
                    {
                        (*currentSection).object[key] = JSONValue("");
                        currentMultilineKey = key;
                        multilineIndent = indent;
                        multilineTarget = currentSection;
                        continue;
                    }
                    
                    // Strip quotes
                    if (value.startsWith("\"") && value.endsWith("\"") && value.length > 1)
                        value = value[1 .. $ - 1];
                    
                    (*currentSection).object[key] = JSONValue(value);
                }
            }
        }
        
        return result;
    }
    
    /// Find first unquoted colon followed by space or end
    private static long findUnquotedColon(string s) @safe pure nothrow
    {
        bool inQuote = false;
        foreach (i, c; s)
        {
            if (c == '"') inQuote = !inQuote;
            else if (!inQuote && c == ':' && (i + 1 >= s.length || s[i + 1] == ' '))
                return cast(long)i;
        }
        return -1;
    }
    
    /// Navigate to a section in nested JSON
    private static JSONValue* navigateToSection(JSONValue* root, string[] path) @system
    {
        JSONValue* current = root;
        foreach (segment; path)
        {
            if (segment in current.object)
                current = &(*current)[segment];
            else
                return root;
        }
        return current;
    }
}
