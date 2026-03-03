module frontend.lsp.providers.definition;

import std.algorithm;
import std.array;
import std.string;
import frontend.lsp.core.protocol;
import frontend.lsp.workspace.workspace;
import infrastructure.config.workspace.ast : BuildFile, TargetDeclStmt, ASTLocation = Location;
import infrastructure.utils.simd.strings : SIMDStrings;

/// Go-to-definition provider
struct DefinitionProvider
{
    private WorkspaceManager workspace;
    
    this(WorkspaceManager workspace)
    {
        this.workspace = workspace;
    }
    
    /// Provide definition location for symbol at position
    Location* provideDefinition(string uri, Position pos)
    {
        auto doc = workspace.getDocument(uri);
        if (doc is null)
            return null;
        
        // Get the word/symbol at the cursor position
        auto symbol = getSymbolAtPosition(doc.text, pos);
        if (symbol.length == 0)
            return null;
        
        // Normalize symbol for lookup
        string targetName = symbol;
        
        // Strip dependency prefix markers - SIMD-accelerated
        if ((() @trusted => SIMDStrings.startsWith(targetName, ":"))())
            targetName = targetName[1 .. $];
        else if ((() @trusted => SIMDStrings.startsWith(targetName, "//"))())
        {
            // Extract just the target name from full path
            auto colonPos = targetName.lastIndexOf(':');
            if (colonPos != -1)
                targetName = targetName[colonPos + 1 .. $];
        }
        
        // Check if it's a target reference - SIMD-accelerated
        if ((() @trusted => SIMDStrings.startsWith(symbol, ":"))() || 
            (() @trusted => SIMDStrings.startsWith(symbol, "//"))())
        {
            return workspace.findDefinition(targetName);
        }
        
        // Check if we're in a deps field (for unquoted or local references)
        auto field = workspace.findFieldAtPosition(uri, pos);
        if (field !is null && field.name == "deps")
        {
            return workspace.findDefinition(targetName);
        }
        
        // Check if cursor is on target name itself (for navigation within file)
        auto target = workspace.findTargetAtPosition(uri, pos);
        if (target !is null && target.name == symbol)
        {
            // Already at definition, no-op (or could show references)
            return null;
        }
        
        return null;
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
        
        // Extend backwards
        while (start > 0 && isSymbolChar(line[start - 1]))
            start--;
        
        // Extend forwards
        while (end < line.length && isSymbolChar(line[end]))
            end++;
        
        // Extract symbol, handling quotes
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
}

