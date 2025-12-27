module frontend.testframework.incremental.selector;

import std.algorithm;
import std.array;
import std.conv;
import std.path;
import engine.caching.incremental.dependency;
import infrastructure.config.schema.schema;
import infrastructure.utils.logging;
import infrastructure.errors;

/// Incremental test selector - determines which tests need to run
/// Integrates with DependencyCache to track test-to-source mappings
final class IncrementalTestSelector
{
    private DependencyCache depCache;
    private string[string] testToSources;  // test_id -> source files covered
    
    this(DependencyCache depCache) @trusted
    {
        this.depCache = depCache;
    }
    
    /// Select tests that need to run based on changed files
    /// Returns: test IDs that should be executed
    string[] selectTests(
        string[] allTestIds,
        string[] changedFiles,
        scope bool delegate(string) isTestFile = null
    ) @system
    {
        if (changedFiles.empty)
            return allTestIds;
        
        bool[string] testsToRun;
        
        // Phase 1: If test file itself changed, run it
        foreach (changed; changedFiles)
        {
            if (isTestFile !is null && isTestFile(changed))
            {
                testsToRun[changed] = true;
                structuredLog.debug_("__direct_test_file_changed_").field("detail", "  [Direct] Test file changed: " ~ changed).emit();
            }
        }
        
        // Phase 2: Find source files affected by changes
        auto depChanges = depCache.analyzeChanges(changedFiles);
        auto affectedSources = depChanges.filesToRebuild;
        
        // Phase 3: Find tests that cover affected sources
        foreach (testId; allTestIds)
        {
            auto sourcesPtr = testId in testToSources;
            if (sourcesPtr is null)
            {
                // No mapping - must run test
                testsToRun[testId] = true;
                continue;
            }
            
            // Check if this test covers any affected source
            auto sources = *sourcesPtr;
            foreach (source; sources.splitter(','))
            {
                if (affectedSources.canFind(source))
                {
                    testsToRun[testId] = true;
                    structuredLog.debug_("__coverage_test_").field("detail", "  [Coverage] Test " ~ testId ~ 
                                  " covers changed source: " ~ source).emit();
                    break;
                }
            }
        }
        
        auto result = testsToRun.keys;
        
        if (result.length < allTestIds.length)
        {
            immutable reduction = ((allTestIds.length - result.length) * 100.0) / 
                                 allTestIds.length;
            structuredLog.info("incremental_test_selection_").field("detail", "Incremental test selection: " ~ result.length.to!string ~ 
                       "/" ~ allTestIds.length.to!string ~ " tests (" ~ 
                       reduction.to!string[0..min(5, $)] ~ "% reduction)").emit();
        }
        
        return result;
    }
    
    /// Record which source files a test covers
    void recordTestCoverage(string testId, string[] sourcesUnderTest) @system
    {
        testToSources[testId] = sourcesUnderTest.join(',');
    }
    
    /// Clear test coverage data
    void clear() @system
    {
        testToSources.clear();
    }
}

