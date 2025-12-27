module engine.compilation.incremental.ast_engine;

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import engine.caching.incremental.ast_dependency;
import engine.caching.incremental.dependency;
import engine.caching.actions.action;
import infrastructure.analysis.ast.parser;
import infrastructure.config.schema.schema;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.errors;

/// AST-level incremental compilation engine
/// Provides fine-grained incremental compilation by tracking symbol-level changes
final class ASTIncrementalEngine
{
    private ASTDependencyCache astCache;
    private DependencyCache fileDepCache;
    private ActionCache actionCache;
    private ASTParserRegistry parserRegistry;
    
    this(
        ASTDependencyCache astCache,
        DependencyCache fileDepCache = null,
        ActionCache actionCache = null
    ) @safe
    {
        this.astCache = astCache;
        this.fileDepCache = fileDepCache;
        this.actionCache = actionCache;
        this.parserRegistry = ASTParserRegistry.instance();
    }
    
    /// Analyze files and determine what needs recompilation at symbol level
    /// This is the main entry point for AST-level incremental compilation
    BuildResult!ASTChangeAnalysis analyzeChanges(
        string[] allSourceFiles,
        string[] changedFiles
    ) @system
    {
        try
        {
            structuredLog.info("ast_incremental_analysis_started").emit();
            
            // Phase 1: Parse changed files and update AST cache
            foreach (changedFile; changedFiles)
            {
                if (!exists(changedFile))
                {
                    structuredLog.debug_("file_deleted").field("file", changedFile).emit();
                    continue;
                }
                
                auto parserResult = parserRegistry.getParser(changedFile);
                if (parserResult.isErr)
                {
                    structuredLog.debug_("no_ast_parser").field("file", changedFile).emit();
                    continue;
                }
                
                auto parser = parserResult.unwrap();
                auto astResult = parser.parseFile(changedFile);
                
                if (astResult.isOk)
                {
                    auto ast = astResult.unwrap();
                    astCache.recordAST(ast);
                    structuredLog.debug_("ast_parsed")
                        .field("file", changedFile)
                        .field("symbols", ast.symbols.length)
                        .emit();
                }
                else
                {
                    structuredLog.warning("ast_parse_failed")
                        .field("file", changedFile)
                        .field("error", astResult.unwrapErr().message())
                        .emit();
                }
            }
            
            // Phase 2: Parse all source files not in cache
            foreach (sourceFile; allSourceFiles)
            {
                auto astResult = astCache.getAST(sourceFile);
                if (astResult.isErr || !astResult.unwrap().isValid())
                {
                    // Need to parse this file
                    if (!exists(sourceFile))
                        continue;
                    
                    auto parserResult = parserRegistry.getParser(sourceFile);
                    if (parserResult.isErr)
                        continue;
                    
                    auto parser = parserResult.unwrap();
                    auto newASTResult = parser.parseFile(sourceFile);
                    
                    if (newASTResult.isOk)
                    {
                        auto ast = newASTResult.unwrap();
                        astCache.recordAST(ast);
                    }
                }
            }
            
            // Phase 3: Analyze symbol-level changes
            auto analysis = astCache.analyzeASTChanges(changedFiles);
            
            // Flush cache to disk
            astCache.flush();
            
            structuredLog.info("ast_analysis_complete")
                .field("files_affected", analysis.filesToRebuild.length)
                .field("symbols_changed", analysis.changedSymbolCount)
                .emit();
            
            return BuildResult!ASTChangeAnalysis.ok(analysis);
        }
        catch (Exception e)
        {
            return BuildResult!ASTChangeAnalysis.err(
                Errors.analysis("", "AST analysis failed: " ~ e.msg, ErrorCode.AnalysisFailed).build());
        }
    }
    
    /// Determine if AST-level compilation is beneficial
    /// Returns true if symbol-level tracking would provide significant benefit
    bool shouldUseASTLevel(string[] sourceFiles) @system
    {
        // AST-level is beneficial when:
        // 1. Files are large (many symbols per file)
        // 2. Many files in project (higher chance of isolated changes)
        // 3. Parser is available for the language
        
        if (sourceFiles.length < 5)
            return false; // Too few files for benefit
        
        size_t parsableFiles;
        foreach (file; sourceFiles)
        {
            if (parserRegistry.canParse(file))
                parsableFiles++;
        }
        
        // Need at least 50% coverage to be useful
        return (parsableFiles * 100 / sourceFiles.length) >= 50;
    }
    
    /// Record successful compilation with AST info
    void recordCompilation(
        string sourceFile,
        ActionId actionId,
        string[] outputs,
        string[string] metadata
    ) @system
    {
        // Record in action cache if available
        if (actionCache !is null)
        {
            actionCache.update(actionId, [sourceFile], outputs, metadata, true);
        }
        
        // AST is already cached from analysis phase
    }
    
    /// Invalidate AST cache for files
    void invalidate(string[] files) @system
    {
        // AST cache handles its own invalidation
        // We don't need to explicitly remove entries as they'll be reparsed on next build
        structuredLog.debug_("ast_cache_invalidating").field("files", files.length).emit();
    }
    
    /// Clear all AST caches
    void clear() @system
    {
        astCache.clear();
    }
    
    /// Get statistics
    struct Stats
    {
        size_t cachedASTs;
        size_t totalSymbols;
        size_t validASTs;
        size_t invalidASTs;
        float avgSymbolsPerFile;
    }
    
    Stats getStats() @system
    {
        Stats stats;
        
        auto cacheStats = astCache.getStats();
        stats.cachedASTs = cacheStats.cachedFiles;
        stats.totalSymbols = cacheStats.totalSymbols;
        stats.validASTs = cacheStats.validASTs;
        stats.invalidASTs = cacheStats.invalidASTs;
        stats.avgSymbolsPerFile = cacheStats.cachedFiles > 0
            ? cast(float)cacheStats.totalSymbols / cacheStats.cachedFiles
            : 0.0;
        
        return stats;
    }
}

/// Helper to integrate AST-level analysis with file-level incremental compilation
/// Provides a unified interface that combines both approaches
final class HybridIncrementalEngine
{
    private ASTIncrementalEngine astEngine;
    private bool useASTLevel;
    
    this(ASTIncrementalEngine astEngine, bool enableAST = true) @safe
    {
        this.astEngine = astEngine;
        this.useASTLevel = enableAST;
    }
    
    /// Analyze changes using the most appropriate strategy
    /// Falls back to file-level if AST-level isn't beneficial
    BuildResult!ASTChangeAnalysis analyzeChanges(
        string[] sourceFiles,
        string[] changedFiles
    ) @system
    {
        if (!useASTLevel || !astEngine.shouldUseASTLevel(sourceFiles))
        {
            structuredLog.debug_("using_file_level_tracking").emit();
            
            // Return simple file-level analysis
            ASTChangeAnalysis analysis;
            analysis.filesToRebuild = changedFiles.dup;
            foreach (file; changedFiles)
                analysis.changeReasons[file] = "file modified (file-level tracking)";
            
            return BuildResult!ASTChangeAnalysis.ok(analysis);
        }
        
        structuredLog.debug_("using_ast_level_incremental").emit();
        return astEngine.analyzeChanges(sourceFiles, changedFiles);
    }
    
    /// Get the underlying AST engine
    ASTIncrementalEngine getASTEngine() @safe
    {
        return astEngine;
    }
    
    /// Enable/disable AST-level compilation
    void setASTLevel(bool enabled) @safe
    {
        useASTLevel = enabled;
    }
    
    bool isASTLevelEnabled() @safe const
    {
        return useASTLevel;
    }
}

