module frontend.lsp.core.protocol;

import std.json;
import std.conv;
import std.algorithm;
import std.array;
import std.json : JSONType;

/// LSP Protocol Version
enum LSP_VERSION = "3.17";

/// Position in a text document (zero-based line and character)
struct Position
{
    uint line;
    uint character;

    JSONValue toJSON() const
    {
        JSONValue json;
        json["line"] = line;
        json["character"] = character;
        return json;
    }

    static Position fromJSON(JSONValue json)
    {
        return Position(
            cast(uint)json["line"].integer,
            cast(uint)json["character"].integer
        );
    }
}

/// Range in a text document
struct Range
{
    Position start;
    Position end;

    JSONValue toJSON() const
    {
        JSONValue json;
        json["start"] = start.toJSON();
        json["end"] = end.toJSON();
        return json;
    }

    static Range fromJSON(JSONValue json)
    {
        return Range(
            Position.fromJSON(json["start"]),
            Position.fromJSON(json["end"])
        );
    }
}

/// Location in a document
struct Location
{
    string uri;
    Range range;

    JSONValue toJSON() const
    {
        JSONValue json;
        json["uri"] = uri;
        json["range"] = range.toJSON();
        return json;
    }

    static Location fromJSON(JSONValue json)
    {
        return Location(
            json["uri"].str,
            Range.fromJSON(json["range"])
        );
    }
}

/// Diagnostic severity
enum DiagnosticSeverity : uint
{
    Error = 1,
    Warning = 2,
    Information = 3,
    Hint = 4
}

/// Diagnostic (error, warning, etc.)
struct Diagnostic
{
    Range range;
    DiagnosticSeverity severity;
    string message;
    string source;

    JSONValue toJSON() const
    {
        JSONValue json;
        json["range"] = range.toJSON();
        json["severity"] = cast(uint)severity;
        json["message"] = message;
        if (source.length > 0)
            json["source"] = source;
        return json;
    }

    static Diagnostic fromJSON(JSONValue json)
    {
        Diagnostic diag;
        diag.range = Range.fromJSON(json["range"]);
        diag.severity = cast(DiagnosticSeverity)json["severity"].integer;
        diag.message = json["message"].str;
        if ("source" in json)
            diag.source = json["source"].str;
        return diag;
    }
}

/// Completion item kind
enum CompletionItemKind : uint
{
    Text = 1,
    Method = 2,
    Function = 3,
    Constructor = 4,
    Field = 5,
    Variable = 6,
    Class = 7,
    Interface = 8,
    Module = 9,
    Property = 10,
    Unit = 11,
    Value = 12,
    Enum = 13,
    Keyword = 14,
    Snippet = 15,
    Color = 16,
    File = 17,
    Reference = 18,
    Folder = 19,
    EnumMember = 20,
    Constant = 21,
    Struct = 22,
    Event = 23,
    Operator = 24,
    TypeParameter = 25
}

/// Completion item
struct CompletionItem
{
    string label;
    CompletionItemKind kind;
    string detail;
    string documentation;
    string insertText;

    JSONValue toJSON() const
    {
        JSONValue json;
        json["label"] = label;
        json["kind"] = cast(uint)kind;
        if (detail.length > 0)
            json["detail"] = detail;
        if (documentation.length > 0)
            json["documentation"] = documentation;
        if (insertText.length > 0)
            json["insertText"] = insertText;
        return json;
    }

    static CompletionItem fromJSON(JSONValue json)
    {
        CompletionItem item;
        item.label = json["label"].str;
        item.kind = cast(CompletionItemKind)json["kind"].integer;
        if ("detail" in json)
            item.detail = json["detail"].str;
        if ("documentation" in json)
            item.documentation = json["documentation"].str;
        if ("insertText" in json)
            item.insertText = json["insertText"].str;
        return item;
    }
}

/// Hover result
struct Hover
{
    string contents;
    Range range;

    JSONValue toJSON() const
    {
        JSONValue json;
        // Use markdown formatted string
        JSONValue markedString;
        markedString["kind"] = "markdown";
        markedString["value"] = contents;
        json["contents"] = markedString;
        json["range"] = range.toJSON();
        return json;
    }
}

/// Text document identifier
struct TextDocumentIdentifier
{
    string uri;

    static TextDocumentIdentifier fromJSON(JSONValue json)
    {
        return TextDocumentIdentifier(json["uri"].str);
    }
}

/// Text document position params
struct TextDocumentPositionParams
{
    TextDocumentIdentifier textDocument;
    Position position;

    static TextDocumentPositionParams fromJSON(JSONValue json)
    {
        return TextDocumentPositionParams(
            TextDocumentIdentifier.fromJSON(json["textDocument"]),
            Position.fromJSON(json["position"])
        );
    }
}

/// Versioned text document identifier
struct VersionedTextDocumentIdentifier
{
    string uri;
    int version_;

    static VersionedTextDocumentIdentifier fromJSON(JSONValue json)
    {
        return VersionedTextDocumentIdentifier(
            json["uri"].str,
            cast(int)json["version"].integer
        );
    }
}

/// Text document item
struct TextDocumentItem
{
    string uri;
    string languageId;
    int version_;
    string text;

    static TextDocumentItem fromJSON(JSONValue json)
    {
        return TextDocumentItem(
            json["uri"].str,
            json["languageId"].str,
            cast(int)json["version"].integer,
            json["text"].str
        );
    }
}

/// Text document content change event
struct TextDocumentContentChangeEvent
{
    Range range;
    string text;

    static TextDocumentContentChangeEvent fromJSON(JSONValue json)
    {
        TextDocumentContentChangeEvent change;
        if ("range" in json)
            change.range = Range.fromJSON(json["range"]);
        change.text = json["text"].str;
        return change;
    }
}

/// Did open text document params
struct DidOpenTextDocumentParams
{
    TextDocumentItem textDocument;

    static DidOpenTextDocumentParams fromJSON(JSONValue json)
    {
        return DidOpenTextDocumentParams(
            TextDocumentItem.fromJSON(json["textDocument"])
        );
    }
}

/// Did change text document params
struct DidChangeTextDocumentParams
{
    VersionedTextDocumentIdentifier textDocument;
    TextDocumentContentChangeEvent[] contentChanges;

    static DidChangeTextDocumentParams fromJSON(JSONValue json)
    {
        DidChangeTextDocumentParams params;
        params.textDocument = VersionedTextDocumentIdentifier.fromJSON(json["textDocument"]);
        
        foreach (change; json["contentChanges"].array)
        {
            params.contentChanges ~= TextDocumentContentChangeEvent.fromJSON(change);
        }
        
        return params;
    }
}

/// Did close text document params
struct DidCloseTextDocumentParams
{
    TextDocumentIdentifier textDocument;

    static DidCloseTextDocumentParams fromJSON(JSONValue json)
    {
        return DidCloseTextDocumentParams(
            TextDocumentIdentifier.fromJSON(json["textDocument"])
        );
    }
}

/// Initialize params (simplified)
struct InitializeParams
{
    int processId;
    string rootUri;
    JSONValue capabilities;

    static InitializeParams fromJSON(JSONValue json)
    {
        InitializeParams params;
        if ("processId" in json && !json["processId"].isNull)
            params.processId = cast(int)json["processId"].integer;
        if ("rootUri" in json && !json["rootUri"].isNull)
            params.rootUri = json["rootUri"].str;
        if ("capabilities" in json)
            params.capabilities = json["capabilities"];
        return params;
    }
}

/// Completion params
struct CompletionParams
{
    TextDocumentIdentifier textDocument;
    Position position;

    static CompletionParams fromJSON(JSONValue json)
    {
        return CompletionParams(
            TextDocumentIdentifier.fromJSON(json["textDocument"]),
            Position.fromJSON(json["position"])
        );
    }
}

/// Rename params
struct RenameParams
{
    TextDocumentIdentifier textDocument;
    Position position;
    string newName;

    static RenameParams fromJSON(JSONValue json)
    {
        return RenameParams(
            TextDocumentIdentifier.fromJSON(json["textDocument"]),
            Position.fromJSON(json["position"]),
            json["newName"].str
        );
    }
}

/// Workspace edit
struct WorkspaceEdit
{
    TextEdit[][string] changes;

    JSONValue toJSON() const
    {
        JSONValue json;
        JSONValue changesJson;
        
        foreach (uri, edits; changes)
        {
            JSONValue[] editsArray;
            foreach (edit; edits)
            {
                editsArray ~= edit.toJSON();
            }
            changesJson[uri] = JSONValue(editsArray);
        }
        
        json["changes"] = changesJson;
        return json;
    }
}

/// Text edit
struct TextEdit
{
    Range range;
    string newText;

    JSONValue toJSON() const
    {
        JSONValue json;
        json["range"] = range.toJSON();
        json["newText"] = newText;
        return json;
    }

    static TextEdit fromJSON(JSONValue json)
    {
        return TextEdit(
            Range.fromJSON(json["range"]),
            json["newText"].str
        );
    }
}

/// Server capabilities for initialize response
struct ServerCapabilities
{
    JSONValue toJSON() const
    {
        JSONValue json;
        
        // Text document sync
        json["textDocumentSync"] = 1; // Full sync
        
        // Completion
        JSONValue completionProvider;
        completionProvider["resolveProvider"] = false;
        completionProvider["triggerCharacters"] = [":", "\"", "/"];
        json["completionProvider"] = completionProvider;
        
        // Hover
        json["hoverProvider"] = true;
        
        // Definition
        json["definitionProvider"] = true;
        
        // References
        json["referencesProvider"] = true;
        
        // Rename
        json["renameProvider"] = true;
        
        // Document formatting
        json["documentFormattingProvider"] = true;
        
        // Document symbols
        json["documentSymbolProvider"] = true;
        
        // CodeLens - inline dependency visualization
        JSONValue codeLensProvider;
        codeLensProvider["resolveProvider"] = true;
        json["codeLensProvider"] = codeLensProvider;
        
        // Execute command (for graph navigation)
        JSONValue executeCommandProvider;
        executeCommandProvider["commands"] = [
            "builder.goToDependency",
            "builder.findReverseDependencies",
            "builder.showDependencyTree",
            "builder.showImpactAnalysis",
            "builder.showDependencyGraph",
            "builder.navigateToTarget"
        ];
        json["executeCommandProvider"] = executeCommandProvider;
        
        return json;
    }
}

/// Execute command params
struct ExecuteCommandParams
{
    string command;
    JSONValue arguments;
    
    static ExecuteCommandParams fromJSON(JSONValue json)
    {
        ExecuteCommandParams params;
        params.command = json["command"].str;
        if ("arguments" in json)
            params.arguments = json["arguments"];
        else
            params.arguments = JSONValue.emptyObject;
        return params;
    }
}

/// Initialize result
struct InitializeResult
{
    ServerCapabilities capabilities;

    JSONValue toJSON() const
    {
        JSONValue json;
        json["capabilities"] = capabilities.toJSON();
        
        // Server info
        JSONValue serverInfo;
        serverInfo["name"] = "Builder LSP";
        serverInfo["version"] = "1.0.0";
        json["serverInfo"] = serverInfo;
        
        return json;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// CodeLens Protocol Structures
// ─────────────────────────────────────────────────────────────────────────────

/// CodeLens represents a command shown inline in the editor
struct CodeLens
{
    Range range;
    Command command;
    JSONValue data;  // Custom data for resolve

    JSONValue toJSON() const
    {
        JSONValue json;
        json["range"] = range.toJSON();
        json["command"] = command.toJSON();
        if (data.type != JSONType.null_)
            json["data"] = data;
        return json;
    }

    static CodeLens fromJSON(JSONValue json)
    {
        CodeLens lens;
        lens.range = Range.fromJSON(json["range"]);
        if ("command" in json)
            lens.command = Command.fromJSON(json["command"]);
        if ("data" in json)
            lens.data = json["data"];
        return lens;
    }
}

/// Command to execute for CodeLens
struct Command
{
    string title;
    string command;
    JSONValue arguments;

    JSONValue toJSON() const
    {
        JSONValue json;
        json["title"] = title;
        json["command"] = command;
        if (arguments.type != JSONType.null_)
            json["arguments"] = arguments;
        return json;
    }

    static Command fromJSON(JSONValue json)
    {
        Command cmd;
        cmd.title = json["title"].str;
        cmd.command = json["command"].str;
        if ("arguments" in json)
            cmd.arguments = json["arguments"];
        return cmd;
    }
}

/// CodeLens request params
struct CodeLensParams
{
    TextDocumentIdentifier textDocument;

    static CodeLensParams fromJSON(JSONValue json)
    {
        return CodeLensParams(TextDocumentIdentifier.fromJSON(json["textDocument"]));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Impact Analysis Visualization Structures
// ─────────────────────────────────────────────────────────────────────────────

/// Impact severity level for visualization
enum ImpactSeverity
{
    Low = 1,      // Affects < 5 targets
    Medium = 2,   // Affects 5-20 targets  
    High = 3,     // Affects 20-50 targets
    Critical = 4  // Affects 50+ targets
}

/// Impact analysis result with visualization data
struct ImpactAnalysis
{
    string targetName;
    ImpactSeverity severity;
    size_t directCount;
    size_t transitiveCount;
    string[] directImpacts;
    string[] criticalPath;
    long estimatedRebuildTime;  // milliseconds

    JSONValue toJSON() const
    {
        JSONValue json;
        json["targetName"] = targetName;
        json["severity"] = cast(int)severity;
        json["severityLabel"] = severityLabel;
        json["directCount"] = directCount;
        json["transitiveCount"] = transitiveCount;
        json["directImpacts"] = directImpacts.map!(s => JSONValue(s)).array;
        json["criticalPath"] = criticalPath.map!(s => JSONValue(s)).array;
        json["estimatedRebuildTime"] = estimatedRebuildTime;
        json["estimatedRebuildTimeFormatted"] = formatDuration(estimatedRebuildTime);
        return json;
    }

    string severityLabel() const pure @safe
    {
        final switch (severity) {
            case ImpactSeverity.Low: return "Low";
            case ImpactSeverity.Medium: return "Medium";
            case ImpactSeverity.High: return "High";
            case ImpactSeverity.Critical: return "Critical";
        }
    }

    private static string formatDuration(long ms) pure @safe
    {
        if (ms < 1000) return ms.to!string ~ "ms";
        if (ms < 60_000) return (ms / 1000).to!string ~ "s";
        return (ms / 60_000).to!string ~ "m " ~ ((ms % 60_000) / 1000).to!string ~ "s";
    }
}

/// Dependency graph node for tree visualization
struct DependencyNode
{
    string name;
    string nodeType;
    int depth;
    bool isLeaf;
    DependencyNode[] children;

    JSONValue toJSON() const
    {
        JSONValue json;
        json["name"] = name;
        json["type"] = nodeType;
        json["depth"] = depth;
        json["isLeaf"] = isLeaf;
        if (children.length > 0)
        {
            JSONValue[] childrenJson;
            foreach (ref child; children)
                childrenJson ~= child.toJSON();
            json["children"] = JSONValue(childrenJson);
        }
        return json;
    }
}

