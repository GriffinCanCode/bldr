module frontend.lsp.providers.rename;

import std.algorithm;
import std.array;
import std.string;
import std.file : readText, exists;
import frontend.lsp.core.protocol;
import frontend.lsp.workspace.workspace;

/// Rename refactoring provider - supports cross-file workspace renames
struct RenameProvider
{
    private WorkspaceManager workspace;
    
    this(WorkspaceManager workspace)
    {
        this.workspace = workspace;
    }
    
    /// Provide workspace edits for renaming symbol at position
    /// Now supports cross-file renaming using workspace index
    WorkspaceEdit* provideRename(string uri, Position pos, string newName)
    {
        // Try to get symbol from open doc first, fall back to reading file
        string text;
        auto doc = workspace.getDocument(uri);
        if (doc !is null)
            text = doc.text;
        else
        {
            string path = uriToPath(uri);
            if (!exists(path)) return null;
            try { text = readText(path); } catch (Exception) { return null; }
        }
        
        // Get the symbol at the cursor
        auto oldName = getSymbolAtPosition(text, pos);
        if (oldName.length == 0)
            return null;
        
        // Normalize: strip prefix for lookup
        string lookupName = normalizeTargetName(oldName);
        
        // Verify target exists in index
        if (!workspace.getIndex().hasTarget(lookupName))
            return null;
        
        // Find all references across workspace (including definition)
        auto references = workspace.findReferences(lookupName);
        auto definition = workspace.findDefinition(lookupName);
        if (definition !is null)
            references ~= *definition;
        
        if (references.length == 0)
            return null;
        
        // Build workspace edit with changes grouped by URI
        auto edit = new WorkspaceEdit;
        
        foreach (ref loc; references)
        {
            TextEdit textEdit;
            textEdit.range = loc.range;
            textEdit.newText = newName;
            
            if (loc.uri !in edit.changes)
                edit.changes[loc.uri] = [];
            edit.changes[loc.uri] ~= textEdit;
        }
        
        return edit;
    }
    
    private string normalizeTargetName(string name)
    {
        if (name.startsWith(":"))
            return name[1 .. $];
        if (name.startsWith("//"))
        {
            auto colonPos = name.lastIndexOf(':');
            if (colonPos != -1)
                return name[colonPos + 1 .. $];
        }
        return name;
    }
    
    private string getSymbolAtPosition(string text, Position pos)
    {
        auto lines = text.split("\n");
        if (pos.line >= lines.length)
            return "";
        
        string line = lines[pos.line];
        if (pos.character >= line.length)
            return "";
        
        // Find word boundaries
        size_t start = pos.character;
        size_t end = pos.character;
        
        while (start > 0 && isSymbolChar(line[start - 1]))
            start--;
        
        while (end < line.length && isSymbolChar(line[end]))
            end++;
        
        string symbol = line[start .. end];
        
        // Remove quotes if present
        if (symbol.startsWith("\"") && symbol.endsWith("\""))
            symbol = symbol[1 .. $ - 1];
        if (symbol.startsWith("'") && symbol.endsWith("'"))
            symbol = symbol[1 .. $ - 1];
        
        return symbol;
    }
    
    private bool isSymbolChar(char c)
    {
        import std.ascii : isAlphaNum;
        return isAlphaNum(c) || c == '_' || c == '-' || c == '/' || c == ':' || c == '.' || c == '"' || c == '\'';
    }
    
    private string uriToPath(string uri)
    {
        if (uri.startsWith("file://"))
            return uri[7 .. $];
        return uri;
    }
}

