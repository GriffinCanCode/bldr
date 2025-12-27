module frontend.lsp.providers.formatting;

import std.algorithm;
import std.array;
import std.string;
import std.conv;
import std.json;
import std.file : readText, exists;
import frontend.lsp.core.protocol;
import frontend.lsp.workspace.workspace;
import infrastructure.utils.simd.strings : SIMDStrings;

/// Document formatting provider for Builderfiles
struct FormattingProvider
{
    private WorkspaceManager workspace;
    
    this(WorkspaceManager workspace) { this.workspace = workspace; }
    
    /// Format entire document
    TextEdit[] provideFormatting(string uri, FormattingOptions options)
    {
        string text = getDocumentText(uri);
        if (text.length == 0) return [];
        
        string formatted = formatBuilderfile(text, options);
        if (formatted == text) return [];  // No changes
        
        // Single edit replacing entire document
        auto lines = text.split("\n");
        return [TextEdit(
            Range(Position(0, 0), Position(cast(uint)lines.length, 0)),
            formatted
        )];
    }
    
    private string getDocumentText(string uri)
    {
        if (auto doc = workspace.getDocument(uri))
            return doc.text;
        
        string path = SIMDStrings.startsWith(uri, "file://") ? uri[7 .. $] : uri;
        if (!exists(path)) return "";
        try { return readText(path); } catch (Exception) { return ""; }
    }
    
    /// Format Builderfile content according to style conventions
    private string formatBuilderfile(string text, FormattingOptions opts)
    {
        auto lines = text.split("\n");
        string[] result;
        
        int indent = 0;
        bool prevBlank = false;
        bool prevComment = false;
        bool inMultilineArray = false;
        
        foreach (rawLine; lines)
        {
            string line = rawLine.stripRight();
            string trimmed = line.strip();
            
            // Handle blank lines (collapse consecutive)
            if (trimmed.length == 0)
            {
                if (!prevBlank && result.length > 0)
                    result ~= "";
                prevBlank = true;
                continue;
            }
            prevBlank = false;
            
            // Dedent before closing braces/brackets
            if (trimmed == "}" || trimmed == "]" || trimmed == "};" || 
                trimmed == "];" || trimmed == "},")
            {
                indent = max(0, indent - 1);
                inMultilineArray = trimmed == "]" || trimmed == "];" || trimmed == "],";
            }
            
            // Format line with proper indent
            string formatted = makeIndent(indent, opts) ~ formatLine(trimmed, indent, opts);
            
            // Ensure blank line before target declarations (not at file start)
            if (isTargetDecl(trimmed) && result.length > 0 && !prevComment)
            {
                string lastLine = result[$ - 1].strip();
                if (lastLine.length > 0 && lastLine != "")
                    result ~= "";
            }
            
            result ~= formatted;
            prevComment = SIMDStrings.startsWith(trimmed, "//") || SIMDStrings.startsWith(trimmed, "#");
            
            // Indent after opening braces/brackets
            if ((trimmed.endsWith("{") || trimmed.endsWith("[")) && 
                !trimmed.canFind("}") && !trimmed.canFind("]"))
            {
                indent++;
                inMultilineArray = trimmed.endsWith("[");
            }
        }
        
        // Trim trailing blanks, ensure final newline
        while (result.length > 0 && result[$ - 1].strip().length == 0)
            result = result[0 .. $ - 1];
        
        return result.join("\n") ~ "\n";
    }
    
    private string makeIndent(int level, FormattingOptions opts)
    {
        return opts.insertSpaces 
            ? replicate(" ", opts.tabSize * level)
            : replicate("\t", level);
    }
    
    private string formatLine(string line, int indent, FormattingOptions opts)
    {
        // Comment pass-through
        if (SIMDStrings.startsWith(line, "//") || SIMDStrings.startsWith(line, "#"))
            return line;
        
        // Field assignment: normalize to "field: value;"
        auto colonIdx = line.indexOf(':');
        if (colonIdx > 0 && !SIMDStrings.startsWith(line, "target") && !SIMDStrings.startsWith(line, "workspace") && 
            !SIMDStrings.startsWith(line, "repository") && !SIMDStrings.endsWith(line, "{"))
        {
            string field = line[0 .. colonIdx].strip();
            string rest = line[colonIdx + 1 .. $].strip();
            
            // Ensure single space after colon
            return field ~ ": " ~ rest;
        }
        
        return line;
    }
    
    private bool isTargetDecl(string line)
    {
        return (SIMDStrings.startsWith(line, "target(") || 
                SIMDStrings.startsWith(line, "workspace(") || 
                SIMDStrings.startsWith(line, "repository(")) && 
               SIMDStrings.endsWith(line, "{");
    }
}

/// Document formatting options from LSP client
struct FormattingOptions
{
    uint tabSize = 4;
    bool insertSpaces = true;
    bool trimTrailingWhitespace = true;
    bool insertFinalNewline = true;
    bool trimFinalNewlines = true;
    
    static FormattingOptions fromJSON(JSONValue json)
    {
        FormattingOptions opts;
        if ("tabSize" in json) 
            opts.tabSize = cast(uint)json["tabSize"].integer;
        if ("insertSpaces" in json) 
            opts.insertSpaces = json["insertSpaces"].boolean;
        if ("trimTrailingWhitespace" in json) 
            opts.trimTrailingWhitespace = json["trimTrailingWhitespace"].boolean;
        if ("insertFinalNewline" in json) 
            opts.insertFinalNewline = json["insertFinalNewline"].boolean;
        if ("trimFinalNewlines" in json) 
            opts.trimFinalNewlines = json["trimFinalNewlines"].boolean;
        return opts;
    }
}

/// Document formatting request params
struct DocumentFormattingParams
{
    TextDocumentIdentifier textDocument;
    FormattingOptions options;
    
    static DocumentFormattingParams fromJSON(JSONValue json)
    {
        return DocumentFormattingParams(
            TextDocumentIdentifier.fromJSON(json["textDocument"]),
            FormattingOptions.fromJSON(json["options"])
        );
    }
}
