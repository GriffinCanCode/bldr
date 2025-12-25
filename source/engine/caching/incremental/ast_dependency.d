module engine.caching.incremental.ast_dependency;

import std.algorithm;
import std.array;
import std.conv : to;
import std.datetime;
import std.file;
import std.path;
import core.sync.mutex;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging.logger;
import infrastructure.errors;

/// AST symbol types for dependency tracking
enum SymbolType
{
    Class,
    Struct,
    Function,
    Method,
    Field,
    Enum,
    Typedef,
    Namespace,
    Template,
    Variable
}

/// Represents a symbol (class, function, etc.) within a source file
struct ASTSymbol
{
    string name;              // Symbol name
    SymbolType type;          // Symbol type
    size_t startLine;         // Starting line number
    size_t endLine;           // Ending line number
    string signature;         // Full signature/declaration
    string contentHash;       // Hash of symbol content
    string[] dependencies;    // Other symbols this depends on
    string[] usedTypes;       // Types used in this symbol
    bool isPublic;           // Whether symbol is public/exported
}

/// File's AST representation with symbols
struct FileAST
{
    string filePath;          // Source file path
    string fileHash;          // Hash of entire file
    ASTSymbol[] symbols;      // Symbols defined in this file
    string[] includes;        // Header dependencies
    SysTime timestamp;        // When AST was parsed
    
    /// Check if AST is still valid
    bool isValid() const @system
    {
        return exists(filePath) && FastHash.hashFile(filePath) == fileHash;
    }
    
    /// Find symbol by name
    const(ASTSymbol)* findSymbol(string symbolName) const @trusted
    {
        foreach (i, ref symbol; symbols)
            if (symbol.name == symbolName)
                return &symbols[i];
        return null;
    }
    
    /// Get changed symbols compared to another AST
    ASTSymbol[] getChangedSymbols(in FileAST other) const @safe
    {
        ASTSymbol[] changed;
        
        foreach (symbol; symbols)
        {
            auto otherSymbol = other.findSymbol(symbol.name);
            if (otherSymbol is null || otherSymbol.contentHash != symbol.contentHash)
                changed ~= ASTSymbol(symbol.name, symbol.type, symbol.startLine, symbol.endLine,
                                      symbol.signature, symbol.contentHash, symbol.dependencies.dup,
                                      symbol.usedTypes.dup, symbol.isPublic);
        }
        
        return changed;
    }
    
    /// Get removed symbols compared to another AST
    string[] getRemovedSymbols(in FileAST other) const @safe
    {
        string[] removed;
        
        foreach (ref otherSymbol; other.symbols)
        {
            if (findSymbol(otherSymbol.name) is null)
                removed ~= otherSymbol.name;
        }
        
        return removed;
    }
}

/// AST-level dependency relationship
/// Tracks symbol-to-symbol dependencies across files
struct ASTDependency
{
    string sourceFile;                    // Source file path
    string sourceSymbol;                  // Symbol name within file
    string[] dependentFiles;              // Files containing symbols we depend on
    string[] dependentSymbols;            // Specific symbols we depend on
    string[string] symbolToFileMap;       // Map symbol name to file path
}

/// Result of AST-level change analysis
struct ASTChangeAnalysis
{
    string[] filesToRebuild;              // Files needing recompilation
    string[string] symbolsToRecompile;    // File -> symbols list (comma-separated)
    string[string] changeReasons;         // File -> reason for rebuild
    size_t changedSymbolCount;            // Total symbols changed
    size_t totalSymbolCount;              // Total symbols analyzed
    float granularity;                    // % of symbols that need recompilation
}

/// AST-level dependency cache
/// Provides fine-grained incremental compilation at symbol level
final class ASTDependencyCache
{
    private string cacheDir;
    private FileAST[string] astCache;           // File -> AST
    private ASTDependency[][string] symbolDeps; // Symbol -> dependencies
    private bool dirty;
    private Mutex mutex;
    
    this(string cacheDir = ".builder-cache/ast-incremental") @system
    {
        this.cacheDir = cacheDir;
        this.dirty = false;
        this.mutex = new Mutex();
        
        if (!exists(cacheDir))
            mkdirRecurse(cacheDir);
        
        load();
    }
    
    /// Record AST for a file
    void recordAST(in FileAST ast) @system
    {
        synchronized (mutex)
        {
            // Create mutable copy
            FileAST mutableAst;
            mutableAst.filePath = ast.filePath;
            mutableAst.fileHash = ast.fileHash;
            // Manual copy for symbols
            mutableAst.symbols = [];
            foreach (sym; ast.symbols)
            {
                mutableAst.symbols ~= ASTSymbol(sym.name, sym.type, sym.startLine, sym.endLine,
                                                 sym.signature, sym.contentHash, sym.dependencies.dup,
                                                 sym.usedTypes.dup, sym.isPublic);
            }
            mutableAst.includes = ast.includes.dup;
            mutableAst.timestamp = ast.timestamp;
            
            astCache[buildNormalizedPath(mutableAst.filePath)] = mutableAst;
            dirty = true;
            
            Logger.debugLog("Recorded AST for " ~ ast.filePath ~ 
                          " with " ~ ast.symbols.length.to!string ~ " symbols");
        }
    }
    
    /// Record symbol-level dependencies
    void recordSymbolDependencies(string file, string symbol, in ASTDependency dep) @system
    {
        synchronized (mutex)
        {
            auto key = buildNormalizedPath(file) ~ "::" ~ symbol;
            // Create mutable copy
            ASTDependency mutableDep;
            mutableDep.sourceFile = dep.sourceFile;
            mutableDep.sourceSymbol = dep.sourceSymbol;
            mutableDep.dependentFiles = dep.dependentFiles.dup;
            mutableDep.dependentSymbols = dep.dependentSymbols.dup;
            // Manual copy for AA
            foreach (k, v; dep.symbolToFileMap)
                mutableDep.symbolToFileMap[k] = v;
            symbolDeps[key] = [mutableDep];
            dirty = true;
        }
    }
    
    /// Get AST for a file
    Result!(FileAST*, BuildError) getAST(string filePath) @system
    {
        synchronized (mutex)
        {
            auto astPtr = buildNormalizedPath(filePath) in astCache;
            return astPtr is null
                ? Result!(FileAST*, BuildError).err(
                    new GenericError("No AST cached for: " ~ filePath, ErrorCode.FileNotFound))
                : Result!(FileAST*, BuildError).ok(astPtr);
        }
    }
    
    /// Analyze changes at AST/symbol level
    /// This is the core algorithm for fine-grained incremental compilation
    ASTChangeAnalysis analyzeASTChanges(string[] changedFiles) @system
    {
        synchronized (mutex)
        {
            ASTChangeAnalysis analysis;
            bool[string] filesToRebuild;
            string[][string] symbolsToRecompile;
            size_t totalSymbols;
            
            // Phase 1: Identify changed symbols in modified files
            foreach (changedFile; changedFiles)
            {
                auto normalizedPath = buildNormalizedPath(changedFile);
                auto oldAST = normalizedPath in astCache;
                
                if (!exists(changedFile))
                {
                    // File deleted - mark for full removal
                    if (oldAST)
                    {
                        filesToRebuild[normalizedPath] = true;
                        analysis.changeReasons[normalizedPath] = "file deleted";
                    }
                    continue;
                }
                
                if (!oldAST)
                {
                    // New file - needs full compilation
                    filesToRebuild[normalizedPath] = true;
                    analysis.changeReasons[normalizedPath] = "new file";
                    continue;
                }
                
                // File exists in cache - check symbol-level changes
                string currentHash = FastHash.hashFile(changedFile);
                if (currentHash == oldAST.fileHash)
                {
                    // No actual changes despite notification
                    continue;
                }
                
                // Mark file as needing rebuild
                filesToRebuild[normalizedPath] = true;
                analysis.changeReasons[normalizedPath] = "symbols modified";
                
                totalSymbols += oldAST.symbols.length;
            }
            
            // Phase 2: Find dependent symbols across all files
            // For each cached file's symbols, check if they depend on changed symbols
            foreach (filePath, fileAST; astCache)
            {
                if (filePath in filesToRebuild)
                    continue; // Already marked for rebuild
                
                totalSymbols += fileAST.symbols.length;
                
                foreach (ref symbol; fileAST.symbols)
                {
                    // Check if this symbol depends on any changed files
                    bool symbolAffected = false;
                    
                    foreach (changedFile; changedFiles)
                    {
                        auto normalizedChanged = buildNormalizedPath(changedFile);
                        
                        // Check includes
                        if (fileAST.includes.canFind(normalizedChanged))
                        {
                            symbolAffected = true;
                            break;
                        }
                        
                        // Check symbol-level dependencies
                        auto depKey = filePath ~ "::" ~ symbol.name;
                        auto deps = depKey in symbolDeps;
                        if (deps)
                        {
                            foreach (dep; *deps)
                            {
                                if (dep.dependentFiles.canFind(normalizedChanged))
                                {
                                    symbolAffected = true;
                                    break;
                                }
                            }
                        }
                    }
                    
                    if (symbolAffected)
                    {
                        symbolsToRecompile[filePath] ~= symbol.name;
                        analysis.changedSymbolCount++;
                    }
                }
                
                if (filePath in symbolsToRecompile && symbolsToRecompile[filePath].length > 0)
                {
                    filesToRebuild[filePath] = true;
                    analysis.changeReasons[filePath] = 
                        "depends on changed symbols: " ~ symbolsToRecompile[filePath].join(", ");
                }
            }
            
            analysis.filesToRebuild = filesToRebuild.keys;
            foreach (file, symbols; symbolsToRecompile)
                analysis.symbolsToRecompile[file] = symbols.join(",");
            
            analysis.totalSymbolCount = totalSymbols;
            analysis.granularity = totalSymbols > 0
                ? (cast(float)analysis.changedSymbolCount / totalSymbols) * 100.0
                : 0.0;
            
            Logger.info("AST-level analysis: " ~
                       analysis.changedSymbolCount.to!string ~ "/" ~
                       analysis.totalSymbolCount.to!string ~ " symbols changed (" ~
                       analysis.granularity.to!string[0..min(5, $)] ~ "% granularity)");
            
            return analysis;
        }
    }
    
    /// Clear cache
    void clear() @system
    {
        synchronized (mutex)
        {
            astCache.clear();
            symbolDeps.clear();
            dirty = true;
        }
    }
    
    /// Flush to disk
    void flush() @system
    {
        synchronized (mutex)
        {
            if (!dirty) return;
            
            try
            {
                save();
                dirty = false;
            }
            catch (Exception e)
            {
                Logger.warning("Failed to flush AST cache: " ~ e.msg);
            }
        }
    }
    
    /// Get cache statistics
    struct Stats
    {
        size_t cachedFiles;
        size_t totalSymbols;
        size_t validASTs;
        size_t invalidASTs;
    }
    
    Stats getStats() @system
    {
        synchronized (mutex)
        {
            Stats stats;
            stats.cachedFiles = astCache.length;
            
            foreach (ast; astCache.values)
            {
                stats.totalSymbols += ast.symbols.length;
                if (ast.isValid())
                    stats.validASTs++;
                else
                    stats.invalidASTs++;
            }
            
            return stats;
        }
    }
    
    private void load() @system
    {
        import engine.caching.incremental.ast_storage;
        
        try
        {
            auto storage = new ASTStorage(cacheDir);
            auto result = storage.load();
            
            if (result.isOk)
            {
                auto loaded = result.unwrap();
                foreach (ast; loaded)
                {
                    auto key = buildNormalizedPath(ast.filePath);
                    astCache[key] = ast;
                }
                
                Logger.debugLog("Loaded " ~ astCache.length.to!string ~ 
                              " AST entries from cache");
            }
        }
        catch (Exception e)
        {
            Logger.debugLog("Failed to load AST cache: " ~ e.msg);
        }
    }
    
    private void save() @system
    {
        import engine.caching.incremental.ast_storage;
        
        auto storage = new ASTStorage(cacheDir);
        auto entries = astCache.values;
        
        auto result = storage.save(entries);
        if (result.isErr)
        {
            Logger.warning("Failed to save AST cache: " ~ 
                         result.unwrapErr().message());
        }
        else
        {
            Logger.debugLog("Saved " ~ entries.length.to!string ~ 
                          " AST entries to cache");
        }
    }
    
    ~this() @nogc nothrow
    {
        // Don't attempt to flush in destructor - allocation is not allowed during GC
        // Users should call flush() explicitly before the cache goes out of scope
    }
}

