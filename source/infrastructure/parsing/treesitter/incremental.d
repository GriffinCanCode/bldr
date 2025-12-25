module infrastructure.parsing.treesitter.incremental;

import std.algorithm : min, max;
import std.array : split;
import std.conv : to;
import std.file : exists, readText;
import std.path : buildNormalizedPath;
import core.sync.mutex;
import infrastructure.parsing.treesitter.bindings;
import infrastructure.parsing.treesitter.config;
import infrastructure.utils.logging.logger;
import infrastructure.errors;

/// Edit operation describing a text change
/// Mirrors tree-sitter's TSInputEdit for incremental parsing
struct TextEdit {
    uint startByte;       /// Byte offset where edit begins
    uint oldEndByte;      /// Byte offset where old text ended
    uint newEndByte;      /// Byte offset where new text ends
    TSPoint startPoint;   /// Start position (row, column)
    TSPoint oldEndPoint;  /// Old end position
    TSPoint newEndPoint;  /// New end position
    
    /// Create edit from line/column positions and text lengths
    static TextEdit fromPositions(
        uint startLine, uint startCol,
        uint oldEndLine, uint oldEndCol,
        uint newEndLine, uint newEndCol,
        string oldContent, string newText
    ) @system {
        TextEdit edit;
        
        edit.startPoint = TSPoint(startLine, startCol);
        edit.oldEndPoint = TSPoint(oldEndLine, oldEndCol);
        edit.newEndPoint = TSPoint(newEndLine, newEndCol);
        
        // Calculate byte offsets from line/column positions
        auto lines = oldContent.split("\n");
        edit.startByte = byteOffsetFromPosition(lines, startLine, startCol);
        edit.oldEndByte = byteOffsetFromPosition(lines, oldEndLine, oldEndCol);
        edit.newEndByte = edit.startByte + cast(uint)newText.length;
        
        return edit;
    }
    
    /// Create edit from byte range (simpler API for file-level changes)
    static TextEdit fromBytes(
        uint startByte, uint oldEndByte, uint newEndByte,
        string oldContent
    ) @system {
        TextEdit edit;
        edit.startByte = startByte;
        edit.oldEndByte = oldEndByte;
        edit.newEndByte = newEndByte;
        
        // Calculate points from bytes
        auto lines = oldContent.split("\n");
        edit.startPoint = pointFromByteOffset(lines, startByte);
        edit.oldEndPoint = pointFromByteOffset(lines, oldEndByte);
        
        // For new end point, calculate from new content position
        uint newLen = newEndByte - startByte;
        if (newLen == 0) {
            edit.newEndPoint = edit.startPoint;
        } else {
            // Estimate based on change size relative to old
            uint lineDelta = (oldEndByte > startByte) 
                ? edit.oldEndPoint.row - edit.startPoint.row 
                : 0;
            edit.newEndPoint = TSPoint(
                edit.startPoint.row + lineDelta,
                (lineDelta == 0) ? edit.startPoint.column + newLen : 0
            );
        }
        
        return edit;
    }
    
    /// Convert to tree-sitter's native edit format
    TSInputEdit toTSEdit() const pure nothrow @nogc {
        TSInputEdit tsEdit;
        tsEdit.start_byte = startByte;
        tsEdit.old_end_byte = oldEndByte;
        tsEdit.new_end_byte = newEndByte;
        tsEdit.start_point = startPoint;
        tsEdit.old_end_point = oldEndPoint;
        tsEdit.new_end_point = newEndPoint;
        return tsEdit;
    }
}

/// Parse result wrapper - holds tree pointer and metadata
struct ParsedTree {
    private TSTree* ptr;
    bool isIncremental;        /// Was this an incremental parse?
    ulong parseTimeNs;         /// Parse duration in nanoseconds
    
    /// Get the raw tree pointer
    TSTree* tree() @system nothrow @nogc { return ptr; }
    
    /// Get root node
    TSNode root() @system nothrow @nogc {
        return ptr ? ts_tree_root_node(ptr) : TSNode.init;
    }
    
    /// Check if valid
    bool isValid() const pure nothrow @nogc { return ptr !is null; }
}

/// Cached parse tree with metadata for incremental updates
private struct TreeCacheEntry {
    TSTree* tree;              /// Parsed tree (owned)
    string content;            /// Last known content
    string contentHash;        /// Hash for validation
    ulong parseTimeNs;         /// Time to parse (nanoseconds)
    uint version_;             /// Monotonic version for sync
    
    /// Apply edits to tree for incremental re-parse
    void applyEdits(const TextEdit[] edits) @system nothrow @nogc {
        if (tree is null) return;
        foreach (ref edit; edits) {
            auto tsEdit = edit.toTSEdit();
            ts_tree_edit(tree, &tsEdit);
        }
    }
    
    /// Release resources
    void release() @system nothrow @nogc {
        if (tree !is null) {
            ts_tree_delete(tree);
            tree = null;
        }
    }
}

/// Incremental parsing cache
/// Caches parsed trees and enables efficient re-parsing using tree-sitter's edit API
final class IncrementalTreeCache {
    private TreeCacheEntry[string] cache;  // path -> entry
    private TSParser*[string] parsers;     // lang -> parser
    private const(TSLanguage)*[string] grammars;
    private Mutex mutex;
    
    // Statistics
    private size_t fullParses;
    private size_t incrementalParses;
    private size_t cacheHits;
    private size_t cacheMisses;
    
    this() @system {
        mutex = new Mutex();
    }
    
    ~this() @system {
        try { clearInternal(); } catch (Exception) {}
    }
    
    /// Register a language grammar for incremental parsing
    void registerGrammar(string langId, const(TSLanguage)* grammar) @system {
        synchronized (mutex) {
            grammars[langId] = grammar;
            
            // Create dedicated parser for this language
            auto parser = ts_parser_new();
            if (parser !is null && grammar !is null) {
                ts_parser_set_language(parser, grammar);
                parsers[langId] = parser;
            }
        }
    }
    
    /// Parse content with incremental optimization
    /// Uses cached tree if available and applies edits for efficient re-parse
    BuildResult!ParsedTree parseIncremental(
        string filePath,
        string content,
        string langId,
        const TextEdit[] edits = null
    ) @system {
        import std.datetime.stopwatch : StopWatch, AutoStart;
        
        auto path = buildNormalizedPath(filePath);
        
        synchronized (mutex) {
            auto parser = langId in parsers;
            if (parser is null || *parser is null) {
                cacheMisses++;
                return BuildResult!ParsedTree.err(
                    Errors.generic("No parser for language: " ~ langId, ErrorCode.UnsupportedLanguage)
                        .withLocation(__FILE__, __LINE__)
                        .build());
            }
            
            auto sw = StopWatch(AutoStart.yes);
            TSTree* oldTree = null;
            bool isIncremental = false;
            
            // Check for cached tree
            auto entry = path in cache;
            if (entry !is null && entry.tree !is null && edits !is null && edits.length > 0) {
                // Apply edits to cached tree for incremental re-parse
                entry.applyEdits(edits);
                oldTree = entry.tree;
                isIncremental = true;
                incrementalParses++;
                cacheHits++;
            } else {
                fullParses++;
                if (entry is null) cacheMisses++;
            }
            
            // Parse (incremental if oldTree provided)
            auto newTree = ts_parser_parse_string(
                *parser, oldTree, content.ptr, cast(uint)content.length);
            
            sw.stop();
            
            if (newTree is null) {
                if (entry !is null) entry.release();
                cache.remove(path);
                return BuildResult!ParsedTree.err(
                    Errors.generic("Parse failed: " ~ filePath, ErrorCode.ParseFailed)
                        .withLocation(__FILE__, __LINE__)
                        .build());
            }
            
            // Update cache (transfer ownership of old tree is handled by ts_parser_parse_string)
            TreeCacheEntry newEntry;
            newEntry.tree = ts_tree_copy(newTree);  // Keep copy in cache
            newEntry.content = content;
            newEntry.parseTimeNs = sw.peek().total!"nsecs";
            newEntry.version_ = entry ? entry.version_ + 1 : 1;
            
            // Release old entry if not used for incremental
            if (entry !is null && !isIncremental) {
                entry.release();
            }
            
            cache[path] = newEntry;
            
            Logger.debugLog(
                (isIncremental ? "Incremental" : "Full") ~ " parse: " ~ filePath ~
                " (" ~ (newEntry.parseTimeNs / 1000).to!string ~ "µs)"
            );
            
            ParsedTree result;
            result.ptr = newTree;
            result.isIncremental = isIncremental;
            result.parseTimeNs = newEntry.parseTimeNs;
            
            return BuildResult!ParsedTree.ok(result);
        }
    }
    
    /// Parse file from disk with incremental optimization
    BuildResult!ParsedTree parseFileIncremental(
        string filePath,
        string langId,
        const TextEdit[] edits = null
    ) @system {
        if (!exists(filePath))
            return BuildResult!ParsedTree.err(
                Errors.generic("File not found: " ~ filePath, ErrorCode.FileNotFound)
                    .withLocation(__FILE__, __LINE__)
                    .build());
        
        try {
            auto content = readText(filePath);
            return parseIncremental(filePath, content, langId, edits);
        } catch (Exception e) {
            return BuildResult!ParsedTree.err(
                Errors.generic("Failed to read: " ~ filePath, ErrorCode.FileReadFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build());
        }
    }
    
    /// Get cached tree for a file (if available)
    TSTree* getCached(string filePath) @system {
        auto path = buildNormalizedPath(filePath);
        synchronized (mutex) {
            auto entry = path in cache;
            return (entry !is null) ? entry.tree : null;
        }
    }
    
    /// Get cached content for a file
    string getCachedContent(string filePath) @system {
        auto path = buildNormalizedPath(filePath);
        synchronized (mutex) {
            auto entry = path in cache;
            return (entry !is null) ? entry.content : null;
        }
    }
    
    /// Invalidate cache for specific files
    void invalidate(string[] paths) @system {
        synchronized (mutex) {
            foreach (path; paths) {
                auto normalized = buildNormalizedPath(path);
                auto entry = normalized in cache;
                if (entry !is null) {
                    entry.release();
                    cache.remove(normalized);
                }
            }
        }
    }
    
    /// Clear all cached trees
    void clear() @system {
        synchronized (mutex) {
            clearInternal();
        }
    }
    
    private void clearInternal() @system {
        foreach (ref entry; cache) {
            entry.release();
        }
        cache.clear();
        
        foreach (parser; parsers) {
            if (parser !is null)
                ts_parser_delete(parser);
        }
        parsers.clear();
    }
    
    /// Statistics for monitoring
    struct Stats {
        size_t cachedTrees;
        size_t fullParses;
        size_t incrementalParses;
        size_t cacheHits;
        size_t cacheMisses;
        float incrementalRate;
        float hitRate;
    }
    
    Stats getStats() @system {
        synchronized (mutex) {
            Stats s;
            s.cachedTrees = cache.length;
            s.fullParses = fullParses;
            s.incrementalParses = incrementalParses;
            s.cacheHits = cacheHits;
            s.cacheMisses = cacheMisses;
            
            auto totalParses = fullParses + incrementalParses;
            s.incrementalRate = totalParses > 0 
                ? (incrementalParses * 100.0f) / totalParses 
                : 0.0f;
            
            auto totalQueries = cacheHits + cacheMisses;
            s.hitRate = totalQueries > 0 
                ? (cacheHits * 100.0f) / totalQueries 
                : 0.0f;
            
            return s;
        }
    }
}

/// Compute byte offset from line/column position
private uint byteOffsetFromPosition(string[] lines, uint line, uint column) @system {
    uint offset = 0;
    foreach (i, l; lines) {
        if (i >= line) break;
        offset += cast(uint)(l.length + 1);  // +1 for newline
    }
    return offset + column;
}

/// Compute TSPoint from byte offset
private TSPoint pointFromByteOffset(string[] lines, uint offset) @system {
    uint currentOffset = 0;
    foreach (row, line; lines) {
        uint lineLen = cast(uint)(line.length + 1);  // +1 for newline
        if (currentOffset + lineLen > offset) {
            return TSPoint(cast(uint)row, offset - currentOffset);
        }
        currentOffset += lineLen;
    }
    // Past end - return last position
    return lines.length > 0 
        ? TSPoint(cast(uint)(lines.length - 1), cast(uint)lines[$ - 1].length)
        : TSPoint(0, 0);
}

/// Adapter for LSP-style text document changes
struct DocumentEdit {
    uint startLine;
    uint startCharacter;
    uint endLine;
    uint endCharacter;
    string newText;
    
    /// Convert to TextEdit using document content
    TextEdit toTextEdit(string documentContent) @system {
        return TextEdit.fromPositions(
            startLine, startCharacter,
            endLine, endCharacter,
            startLine + countLines(newText), lastLineLength(newText),
            documentContent, newText
        );
    }
}

/// Count newlines in text
private uint countLines(string text) pure nothrow @nogc {
    uint count = 0;
    foreach (c; text) if (c == '\n') count++;
    return count;
}

/// Get length of last line
private uint lastLineLength(string text) pure nothrow @nogc {
    uint len = 0;
    foreach_reverse (c; text) {
        if (c == '\n') break;
        len++;
    }
    return len;
}

/// Global incremental tree cache singleton
private __gshared IncrementalTreeCache globalCache_;

/// Get the global incremental tree cache
IncrementalTreeCache incrementalTreeCache() @system {
    if (globalCache_ is null)
        globalCache_ = new IncrementalTreeCache();
    return globalCache_;
}

