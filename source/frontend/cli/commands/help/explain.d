module frontend.cli.commands.help.explain;

import std.stdio;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.conv;
import std.json;
import infrastructure.utils.logging.logger;
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
                    Logger.error("Usage: builder explain search <query>");
                    return;
                }
                performSearch(args[2 .. $].join(" "));
                break;
            
            case "example":
                if (args.length < 3)
                {
                    Logger.error("Usage: builder explain example <topic>");
                    return;
                }
                showExamples(args[2]);
                break;
            
            case "workflow":
                if (args.length < 3)
                {
                    Logger.error("Usage: builder explain workflow <workflow-name>");
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
        writeln("  builder explain <topic>              Show topic documentation (smart match)");
        writeln("  builder explain list                 List all available topics");
        writeln("  builder explain search <query>       Search across all topics");
        writeln("  builder explain example <topic>      Show working examples");
        writeln("  builder explain workflow <name>      Show step-by-step workflow");
        writeln();
        writeln("AVAILABLE TOPICS:");
        writeln("  blake3           BLAKE3 hash function - 3-5x faster than SHA-256");
        writeln("  caching          Multi-tier caching: target, action, remote");
        writeln("  determinism      Bit-for-bit reproducible builds");
        writeln("  incremental      Module-level incremental compilation");
        writeln("  action-cache     Fine-grained action caching");
        writeln("  remote-cache     Distributed cache for teams/CI");
        writeln();
        writeln("EXAMPLES:");
        writeln("  builder explain blake3");
        writeln("  builder explain \"fast builds\"");
        writeln("  builder explain example caching");
        writeln();
    }
    
    /// List all available topics
    private static void listTopics() @system
    {
        auto indexPath = buildPath(getDocsPath(), "ai", "index.yaml");
        
        if (!exists(indexPath))
        {
            Logger.error("AI documentation index not found at: " ~ indexPath);
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
            Logger.error("Failed to read index: " ~ e.msg);
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
                Logger.error("Topic found in index but file missing: " ~ matchTopic);
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
            writefln("Found %d related topics. Use 'builder explain <topic>' to view.", matches.length);
        }
        else
        {
            Logger.error("Topic not found: " ~ query);
            writeln("\nAvailable topics:");
            writeln("  builder explain list");
        }
    }
    
    /// Perform search and display results
    private static void performSearch(string query) @system
    {
        auto matches = findMatches(query);
        
        writeln();
        if (matches.length == 0)
        {
            Logger.info("No topics found matching: " ~ query);
            writeln("\nTry: builder explain list");
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
            writefln("Found %d topic(s). Use 'builder explain <topic>' for details.", matches.length);
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
            Logger.error("Search failed: " ~ e.msg);
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
            Logger.error("Failed to read topic: " ~ e.msg);
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
            Logger.error("Topic not found: " ~ topic);
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
            Logger.error("Failed to read examples: " ~ e.msg);
        }
    }
    
    /// Show workflow documentation
    private static void showWorkflow(string workflow) @system
    {
        Logger.info("Workflows not yet implemented. Coming soon!");
        writeln("\nCurrently available: builder explain <topic>");
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
            Logger.info("No examples available for this topic.");
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
    /// This is a minimal parser for the specific YAML structure we use
    private static JSONValue parseSimpleYAML(string content) @system
    {
        JSONValue result;
        result.object = null;
        
        string[] lines = content.split("\n");
        JSONValue* currentSection = &result;
        string[] sectionStack;
        int[] indentStack = [0];
        
        string currentMultilineKey = null;
        bool multilineIsArray = false;
        int multilineIndent = -1;
        
        foreach (line; lines)
        {
            auto stripped = line.strip();
            
            // Handle blank lines
            if (stripped.length == 0)
            {
                if (currentMultilineKey !is null || multilineIsArray)
                {
                    string text = "\n";
                    if (multilineIsArray)
                    {
                        auto arr = (*currentSection).array;
                        if (arr.length > 0)
                        {
                            // Check if last item is string
                            if (arr[$-1].type == JSONType.string)
                            {
                                string current = arr[$-1].str;
                                arr[$-1] = JSONValue(current ~ text);
                                (*currentSection).array = arr;
                            }
                        }
                    }
                    else if (currentMultilineKey in (*currentSection).object)
                    {
                        string current = (*currentSection).object[currentMultilineKey].str;
                        (*currentSection).object[currentMultilineKey] = JSONValue(current ~ text);
                    }
                }
                continue;
            }
            
            if (stripped.startsWith("#"))
                continue;
            
            auto indent = line.length - line.stripLeft().length;
            
            // Check continuation of multiline string
            if ((currentMultilineKey !is null || multilineIsArray) && multilineIndent != -1)
            {
                if (indent > multilineIndent)
                {
                    string text = stripped ~ "\n";
                    
                    if (multilineIsArray)
                    {
                        auto arr = (*currentSection).array;
                        if (arr.length > 0 && arr[$-1].type == JSONType.string)
                        {
                            string current = arr[$-1].str;
                            arr[$-1] = JSONValue(current ~ text);
                            (*currentSection).array = arr;
                        }
                    }
                    else if (currentMultilineKey in (*currentSection).object)
                    {
                        string current = (*currentSection).object[currentMultilineKey].str;
                        (*currentSection).object[currentMultilineKey] = JSONValue(current ~ text);
                    }
                    continue;
                }
                else
                {
                    // End of block
                    currentMultilineKey = null;
                    multilineIsArray = false;
                    multilineIndent = -1;
                }
            }
            
            if (stripped.endsWith(":"))
            {
                // Section or key
                auto key = stripped[0 .. $ - 1];
                
                if (indent <= indentStack[$ - 1] && sectionStack.length > 0)
                {
                    // Pop stack
                    while (indentStack.length > 1 && indent <= indentStack[$ - 1])
                    {
                        sectionStack = sectionStack[0 .. $ - 1];
                        indentStack = indentStack[0 .. $ - 1];
                        currentSection = navigateToSection(&result, sectionStack);
                    }
                }
                
                (*currentSection).object[key] = JSONValue();
                (*currentSection)[key].object = null;
                
                sectionStack ~= key;
                indentStack ~= cast(int)indent;
                currentSection = &(*currentSection)[key];
            }
            else if (stripped.startsWith("- "))
            {
                // Array item
                auto valueStr = stripped[2 .. $].strip();
                JSONValue val;
                
                // Check for object in array (e.g. "- key: value")
                // But ignore : inside quotes
                long sepIndex = -1;
                bool inQuote = false;
                for (size_t i = 0; i < valueStr.length - 1; i++)
                {
                    if (valueStr[i] == '"' && (i == 0 || valueStr[i-1] != '\\'))
                        inQuote = !inQuote;
                    
                    if (!inQuote && valueStr[i] == ':' && valueStr[i+1] == ' ')
                    {
                        sepIndex = i;
                        break;
                    }
                }
                
                if (sepIndex != -1)
                {
                    auto key = valueStr[0 .. sepIndex].strip();
                    auto v = valueStr[sepIndex + 2 .. $].strip();
                    if (v.startsWith("\"") && v.endsWith("\""))
                        v = v[1 .. $ - 1];
                        
                    val = JSONValue([key: JSONValue(v)]);
                }
                else
                {
                    if (valueStr.startsWith("\"") && valueStr.endsWith("\""))
                        valueStr = valueStr[1 .. $ - 1];
                        
                    val = JSONValue(valueStr);
                    
                    // Handle multiline array item
                    if (valueStr == "|")
                    {
                        val = JSONValue("");
                        multilineIsArray = true;
                        multilineIndent = cast(int)indent;
                    }
                }
                
                if ((*currentSection).type != JSONType.array)
                    (*currentSection).array = null;
                
                (*currentSection).array ~= val;
            }
            else if (stripped.canFind(": "))
            {
                // Key-value pair
                auto parts = stripped.split(": ");
                if (parts.length >= 2)
                {
                    auto key = parts[0].strip();
                    auto value = parts[1 .. $].join(": ").strip();
                    
                    // Handle multiline strings (|)
                    if (value == "|")
                    {
                        JSONValue empty = JSONValue("");
                        currentMultilineKey = key;
                        multilineIsArray = false;
                        multilineIndent = cast(int)indent;
                        
                        if ((*currentSection).type == JSONType.array && (*currentSection).array.length > 0 && 
                            (*currentSection).array[$ - 1].type == JSONType.object)
                            (*currentSection).array[$ - 1].object[key] = empty;
                        else
                            (*currentSection).object[key] = empty;
                        continue;
                    }
                    
                    if (value.startsWith("\"") && value.endsWith("\""))
                        value = value[1 .. $ - 1];
                    
                    // If we're in an array and the last item is an object, assume this key belongs to it
                    // This handles YAML list of objects where keys are on subsequent lines
                    if ((*currentSection).type == JSONType.array && (*currentSection).array.length > 0 && 
                        (*currentSection).array[$ - 1].type == JSONType.object)
                    {
                        (*currentSection).array[$ - 1].object[key] = JSONValue(value);
                    }
                    else
                    {
                        (*currentSection).object[key] = JSONValue(value);
                    }
                }
            }
        }
        
        return result;
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
