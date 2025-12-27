module infrastructure.parsing.treesitter.adapter;

import std.algorithm : max, min;
import std.array : split;
import std.conv : to;
import std.file : exists, readText;
import std.path : buildNormalizedPath, extension;
import infrastructure.parsing.treesitter.incremental;
import infrastructure.parsing.treesitter.config;
import infrastructure.parsing.treesitter.registry;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.files.watch : FileEvent, FileEventKind;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.errors;
import engine.caching.incremental.ast_dependency;

/// Incremental parsing adapter for watch mode
/// Bridges file change events to incremental tree-sitter parsing
final class IncrementalParseAdapter {
    private string[string] contentCache;  // path -> last content
    private bool enabled;
    
    /// Create adapter with optional enable flag
    this(bool enable = true) @system {
        this.enabled = enable;
    }
    
    /// Process file change events and return updated ASTs
    /// Uses incremental parsing when possible
    FileAST[] processChanges(const FileEvent[] events) @system {
        if (!enabled || events.length == 0)
            return [];
        
        FileAST[] results;
        
        foreach (ref event; events) {
            auto result = processEvent(event);
            if (result.isOk)
                results ~= result.unwrap();
        }
        
        return results;
    }
    
    /// Process a single file event
    BuildResult!FileAST processEvent(const ref FileEvent event) @system {
        import std.path : extension;
        
        auto path = buildNormalizedPath(event.path);
        auto ext = extension(path);
        
        // Get parser for this file type
        auto registry = ASTParserRegistry.instance();
        if (!registry.canParse(path))
            return BuildResult!FileAST.err(
                Errors.generic("No parser for: " ~ ext, ErrorCode.UnsupportedLanguage)
                    .withLocation(__FILE__, __LINE__)
                    .build());
        
        switch (event.kind) {
            case FileEventKind.Deleted:
                return handleDeletion(path);
            
            case FileEventKind.Created:
                return handleCreation(path);
            
            case FileEventKind.Modified:
            case FileEventKind.Renamed:
            default:
                return handleModification(path);
        }
    }
    
    /// Handle file deletion
    private BuildResult!FileAST handleDeletion(string path) @system {
        // Invalidate caches
        contentCache.remove(path);
        incrementalTreeCache().invalidate([path]);
        
        // Return empty AST for deleted file
        FileAST ast;
        ast.filePath = path;
        ast.fileHash = "";
        ast.symbols = [];
        ast.includes = [];
        
        return BuildResult!FileAST.ok(ast);
    }
    
    /// Handle new file creation
    private BuildResult!FileAST handleCreation(string path) @system {
        if (!exists(path))
            return BuildResult!FileAST.err(
                Errors.generic("File not found: " ~ path, ErrorCode.FileNotFound)
                    .withLocation(__FILE__, __LINE__)
                    .build());
        
        // Parse fresh
        return parseFile(path, null);
    }
    
    /// Handle file modification with incremental parsing
    private BuildResult!FileAST handleModification(string path) @system {
        if (!exists(path))
            return handleDeletion(path);
        
        try {
            auto newContent = readText(path);
            auto oldContent = path in contentCache;
            
            TextEdit[] edits;
            
            if (oldContent !is null && *oldContent != newContent) {
                // Compute edits from diff
                edits = computeEdits(*oldContent, newContent);
            }
            
            // Cache new content
            contentCache[path] = newContent;
            
            // Parse with edits
            return parseFile(path, edits);
        } catch (Exception e) {
            return BuildResult!FileAST.err(
                Errors.generic("Failed to read: " ~ path ~ " - " ~ e.msg, ErrorCode.FileReadFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build());
        }
    }
    
    /// Parse file using incremental parser if available
    private BuildResult!FileAST parseFile(string path, TextEdit[] edits) @system {
        import infrastructure.parsing.treesitter.parser : TreeSitterParser;
        
        auto registry = ASTParserRegistry.instance();
        auto parserResult = registry.getParser(path);
        
        if (parserResult.isErr)
            return BuildResult!FileAST.err(parserResult.unwrapErr());
        
        auto parser = parserResult.unwrap();
        
        // Check if it's a TreeSitterParser for incremental support
        if (auto tsParser = cast(TreeSitterParser)parser) {
            if (edits !is null && edits.length > 0)
                return tsParser.parseFileWithEdits(path, edits);
        }
        
        // Fallback to regular parse
        return parser.parseFile(path);
    }
    
    /// Compute edits between old and new content using line-level diff
    /// Returns coarse edits - tree-sitter will refine internally
    private TextEdit[] computeEdits(string oldContent, string newContent) @system {
        auto oldLines = oldContent.split("\n");
        auto newLines = newContent.split("\n");
        
        TextEdit[] edits;
        
        // Simple line-level diff: find first and last differing lines
        size_t firstDiff = 0;
        while (firstDiff < oldLines.length && firstDiff < newLines.length) {
            if (oldLines[firstDiff] != newLines[firstDiff])
                break;
            firstDiff++;
        }
        
        size_t oldEnd = oldLines.length;
        size_t newEnd = newLines.length;
        
        // Scan from end to find last difference
        while (oldEnd > firstDiff && newEnd > firstDiff) {
            if (oldLines[oldEnd - 1] != newLines[newEnd - 1])
                break;
            oldEnd--;
            newEnd--;
        }
        
        if (firstDiff < oldLines.length || firstDiff < newLines.length) {
            // Calculate byte offsets
            uint startByte = lineToByteOffset(oldLines, firstDiff);
            uint oldEndByte = lineToByteOffset(oldLines, oldEnd);
            uint newEndByte = startByte + byteLength(newLines, firstDiff, newEnd);
            
            edits ~= TextEdit.fromBytes(startByte, oldEndByte, newEndByte, oldContent);
        }
        
        return edits;
    }
    
    /// Calculate byte offset at start of line
    private uint lineToByteOffset(string[] lines, size_t lineNum) @system {
        uint offset = 0;
        foreach (i; 0 .. min(lineNum, lines.length)) {
            offset += cast(uint)(lines[i].length + 1);  // +1 for newline
        }
        return offset;
    }
    
    /// Calculate byte length of line range
    private uint byteLength(string[] lines, size_t start, size_t end) @system {
        uint len = 0;
        foreach (i; start .. min(end, lines.length)) {
            len += cast(uint)(lines[i].length + 1);
        }
        return len;
    }
    
    /// Pre-cache content for a set of files
    void preCacheContent(string[] paths) @system {
        foreach (path; paths) {
            if (exists(path)) {
                try {
                    contentCache[buildNormalizedPath(path)] = readText(path);
                } catch (Exception) {
                    // Ignore errors during pre-caching
                }
            }
        }
    }
    
    /// Clear all caches
    void clear() @system {
        contentCache.clear();
        incrementalTreeCache().clear();
    }
    
    /// Get statistics
    struct Stats {
        size_t cachedFiles;
        IncrementalTreeCache.Stats treeStats;
    }
    
    Stats getStats() @system {
        Stats s;
        s.cachedFiles = contentCache.length;
        s.treeStats = incrementalTreeCache().getStats();
        return s;
    }
}

/// LSP document change adapter
/// Converts LSP text document changes to incremental edits
struct LSPChangeAdapter {
    /// Convert LSP content change event to TextEdit
    static TextEdit fromContentChange(
        uint startLine, uint startChar,
        uint endLine, uint endChar,
        string newText,
        string documentContent
    ) @system {
        return TextEdit.fromPositions(
            startLine, startChar,
            endLine, endChar,
            startLine + countNewlines(newText),
            lastLineLength(startChar, newText),
            documentContent, newText
        );
    }
    
    /// Count newlines in text
    private static uint countNewlines(string text) pure nothrow @nogc {
        uint count = 0;
        foreach (c; text) if (c == '\n') count++;
        return count;
    }
    
    /// Calculate last line length accounting for start column
    private static uint lastLineLength(uint startCol, string text) pure nothrow @nogc {
        uint len = 0;
        bool hasNewline = false;
        foreach_reverse (c; text) {
            if (c == '\n') {
                hasNewline = true;
                break;
            }
            len++;
        }
        return hasNewline ? len : startCol + len;
    }
}

/// Global adapter instance for watch mode
private __gshared IncrementalParseAdapter globalAdapter_;

/// Get the global incremental parse adapter
IncrementalParseAdapter incrementalParseAdapter() @system {
    if (globalAdapter_ is null)
        globalAdapter_ = new IncrementalParseAdapter();
    return globalAdapter_;
}

