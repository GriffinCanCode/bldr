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
            
            case "directory":
            case "dir":
                showDirectory();
                break;
            
            case "search":
                if (args.length < 3)
                {
                    Logger.error("Usage: bldr explain search <query>");
                    return;
                }
                performSearch(args[2 .. $].join(" "));
                break;
            
            case "example":
                if (args.length < 3)
                {
                    Logger.error("Usage: bldr explain example <topic>");
                    return;
                }
                showExamples(args[2]);
                break;
            
            case "workflow":
                if (args.length < 3)
                {
                    Logger.error("Usage: bldr explain workflow <workflow-name>");
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
        writeln("  bldr explain <topic>              Show topic documentation");
        writeln("  bldr explain directory            Browse all topics by category");
        writeln("  bldr explain list                 List all topics alphabetically");
        writeln("  bldr explain search <query>       Search across all topics");
        writeln("  bldr explain example <topic>      Show working examples");
        writeln();
        writeln("QUICK START:");
        writeln("  bldr explain caching              Learn about build caching");
        writeln("  bldr explain determinism          Reproducible builds");
        writeln("  bldr explain targets              Build target basics");
        writeln();
        writeln("TIP: Run 'bldr explain directory' to see all available topics.");
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
    
    /// Show directory of all topics grouped by category
    private static void showDirectory() @system
    {
        auto indexPath = buildPath(getDocsPath(), "ai", "index.yaml");
        
        if (!exists(indexPath))
        {
            Logger.error("AI documentation index not found");
            return;
        }
        
        try
        {
            auto index = parseYAMLIndex(indexPath);
            
            writeln();
            writeln("=== Builder Documentation Directory ===");
            writeln();
            
            if ("concepts" !in index || index["concepts"].type != JSONType.object)
            {
                Logger.error("No topics found in index");
                return;
            }
            
            // Group topics by category based on file path
            string[][string] byCategory;
            string[string] summaries;
            
            foreach (topic, data; index["concepts"].object)
            {
                if (data.type != JSONType.object) continue;
                
                string file = "file" in data ? data["file"].str : "";
                string summary = "summary" in data ? data["summary"].str : "";
                summaries[topic] = summary;
                
                // Extract category from file path (e.g., "concepts/core/caching.yaml" -> "core")
                string category = "other";
                if (file.length > 0)
                {
                    auto parts = file.split("/");
                    if (parts.length >= 2)
                        category = parts[1];  // concepts/CATEGORY/file.yaml
                }
                
                if (category !in byCategory)
                    byCategory[category] = [];
                byCategory[category] ~= topic;
            }
            
            // Category display order and names
            string[string] categoryNames = [
                "core": "Core Concepts",
                "config": "Configuration",
                "languages": "Language Support", 
                "rules": "Rules & Starlark",
                "ecosystem": "Ecosystem & Tools",
                "reference": "Reference"
            ];
            
            string[] categoryOrder = ["core", "config", "languages", "rules", "ecosystem", "reference", "other"];
            
            foreach (cat; categoryOrder)
            {
                if (cat !in byCategory) continue;
                
                auto topics = byCategory[cat];
                topics.sort();
                
                string catName = cat in categoryNames ? categoryNames[cat] : cat.toUpper();
                writeln("\x1b[1m" ~ catName ~ "\x1b[0m");
                
                foreach (topic; topics)
                {
                    string summary = topic in summaries ? summaries[topic] : "";
                    // Truncate summary if too long
                    if (summary.length > 50)
                        summary = summary[0..47] ~ "...";
                    writefln("  \x1b[36m%-22s\x1b[0m %s", topic, summary);
                }
                writeln();
            }
            
            writeln("Use 'bldr explain <topic>' to view any topic.");
            writeln();
        }
        catch (Exception e)
        {
            Logger.error("Failed to read directory: " ~ e.msg);
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
            writefln("Found %d related topics. Use 'bldr explain <topic>' to view.", matches.length);
        }
        else
        {
            Logger.error("Topic not found: " ~ query);
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
            Logger.info("No topics found matching: " ~ query);
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
        writeln("\nCurrently available: bldr explain <topic>");
    }
    
    /// Display topic documentation
    private static void displayTopic(JSONValue doc) @system
    {
        writeln();
        
        // === TOPIC ===
        if ("topic" in doc)
        {
            writeln("=== " ~ doc["topic"].str.toUpper() ~ " ===");
            writeln();
        }
        
        // SUMMARY: Use definition if available (fuller explanation), fallback to summary
        string summaryText;
        if ("definition" in doc)
            summaryText = doc["definition"].str;
        else if ("summary" in doc)
            summaryText = doc["summary"].str;
            
        if (summaryText.length > 0)
        {
            writeln("\x1b[1mSUMMARY:\x1b[0m");
            writeln();
            foreach (line; summaryText.split("\n"))
                if (line.strip().length > 0)
                    writeln(line.strip());
            writeln();
        }
        
        // KEY POINTS:
        if ("key_points" in doc && doc["key_points"].type == JSONType.array)
        {
            writeln("\x1b[1mKEY POINTS:\x1b[0m");
            writeln();
            foreach (point; doc["key_points"].array)
                writeln("• " ~ point.str);
            writeln();
        }
        
        // USAGE: Show code example - try multiple sources
        string usageCode;
        
        // 1. Try usage_examples with code field
        if ("usage_examples" in doc && doc["usage_examples"].type == JSONType.array)
        {
            foreach (example; doc["usage_examples"].array)
            {
                if (example.type == JSONType.object && "code" in example)
                {
                    usageCode = example["code"].str;
                    break;
                }
            }
        }
        
        // 2. Try example field (some YAML files use this)
        if (usageCode.length == 0 && "example" in doc)
            usageCode = doc["example"].str;
        
        // 3. Try usage field (can be string or object with sub-fields)
        if (usageCode.length == 0 && "usage" in doc)
        {
            if (doc["usage"].type == JSONType.string)
                usageCode = doc["usage"].str;
            else if (doc["usage"].type == JSONType.object)
            {
                // Try first sub-field of usage object
                foreach (key, val; doc["usage"].object)
                {
                    if (val.type == JSONType.string)
                    {
                        usageCode = val.str;
                        break;
                    }
                }
            }
        }
        
        // Display if we found code
        if (usageCode.length > 0)
        {
            writeln("\x1b[1mUSAGE:\x1b[0m");
            writeln();
            foreach (line; usageCode.split("\n"))
                if (line.length > 0)
                    writeln(line);
            writeln();
        }
        
        // RELATED:
        if ("related" in doc)
        {
            string relatedStr;
            if (doc["related"].type == JSONType.array)
                relatedStr = doc["related"].array.map!(r => r.str).array.join(", ");
            else if (doc["related"].type == JSONType.string)
                // Handle inline array syntax [a, b, c] stored as string
                relatedStr = doc["related"].str.strip("[]").replace(", ", ", ");
            
            if (relatedStr.length > 0)
            {
                writeln("\x1b[1mRELATED:\x1b[0m " ~ relatedStr);
                writeln();
            }
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
        JSONValue result = parseJSON("{}");  // Initialize as empty object
        
        string[] lines = content.split("\n");
        JSONValue* currentSection = &result;
        string[] sectionStack;
        int[] indentStack = [0];
        
        string currentMultilineKey = null;
        bool multilineIsArray = false;
        bool multilineInArrayItem = false;  // Track if multiline key is in an array item
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
                        if (arr.length > 0 && arr[$-1].type == JSONType.string)
                        {
                            arr[$-1] = JSONValue(arr[$-1].str ~ text);
                            (*currentSection).array = arr;
                        }
                    }
                    else if (multilineInArrayItem && (*currentSection).type == JSONType.array)
                    {
                        // Multiline key in array item
                        auto arr = (*currentSection).array;
                        if (arr.length > 0 && arr[$-1].type == JSONType.object && currentMultilineKey in arr[$-1].object)
                        {
                            arr[$-1].object[currentMultilineKey] = JSONValue(arr[$-1].object[currentMultilineKey].str ~ text);
                            (*currentSection).array = arr;
                        }
                    }
                    else if ((*currentSection).type == JSONType.object && currentMultilineKey in (*currentSection).object)
                    {
                        (*currentSection).object[currentMultilineKey] = JSONValue((*currentSection).object[currentMultilineKey].str ~ text);
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
                    // Preserve relative indentation (content indent - base indent)
                    auto relativeIndent = cast(int)indent - multilineIndent - 2;  // -2 for typical YAML indent
                    string indentStr = relativeIndent > 0 ? replicate(" ", relativeIndent) : "";
                    string text = indentStr ~ stripped ~ "\n";
                    
                    if (multilineIsArray)
                    {
                        auto arr = (*currentSection).array;
                        if (arr.length > 0 && arr[$-1].type == JSONType.string)
                        {
                            arr[$-1] = JSONValue(arr[$-1].str ~ text);
                            (*currentSection).array = arr;
                        }
                    }
                    else if (multilineInArrayItem && (*currentSection).type == JSONType.array)
                    {
                        // Multiline key in array item
                        auto arr = (*currentSection).array;
                        if (arr.length > 0 && arr[$-1].type == JSONType.object && currentMultilineKey in arr[$-1].object)
                        {
                            arr[$-1].object[currentMultilineKey] = JSONValue(arr[$-1].object[currentMultilineKey].str ~ text);
                            (*currentSection).array = arr;
                        }
                    }
                    else if ((*currentSection).type == JSONType.object && currentMultilineKey in (*currentSection).object)
                    {
                        (*currentSection).object[currentMultilineKey] = JSONValue((*currentSection).object[currentMultilineKey].str ~ text);
                    }
                    continue;
                }
                else
                {
                    // End of block
                    currentMultilineKey = null;
                    multilineIsArray = false;
                    multilineInArrayItem = false;
                    multilineIndent = -1;
                }
            }
            
            if (stripped.endsWith(":"))
            {
                // Section or key
                auto key = stripped[0 .. $ - 1];
                
                // Always check indentation and pop as needed
                while (sectionStack.length > 0 && indent <= indentStack[$ - 1])
                {
                    sectionStack = sectionStack[0 .. $ - 1];
                    indentStack = indentStack[0 .. $ - 1];
                }
                currentSection = navigateToSection(&result, sectionStack);
                
                // Safety: if current section became an array, go to root
                if ((*currentSection).type != JSONType.object)
                {
                    currentSection = &result;
                    sectionStack = [];
                    indentStack = [0];
                }
                
                (*currentSection).object[key] = parseJSON("{}");
                
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
                    *currentSection = parseJSON("[]");
                
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
                        {
                            (*currentSection).array[$ - 1].object[key] = empty;
                            multilineInArrayItem = true;
                        }
                        else if ((*currentSection).type == JSONType.object)
                        {
                            (*currentSection).object[key] = empty;
                            multilineInArrayItem = false;
                        }
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
                    else if ((*currentSection).type == JSONType.object)
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
            // Only navigate if current is an object
            if ((*current).type != JSONType.object)
                return root;
            if (segment in (*current).object)
                current = &(*current)[segment];
            else
                return root;
        }
        // Return root if final destination is not an object
        if ((*current).type != JSONType.object)
            return root;
        return current;
    }
}
