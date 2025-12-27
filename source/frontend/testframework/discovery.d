module frontend.testframework.discovery;

import std.algorithm : filter, canFind, startsWith, endsWith, countUntil;
import std.array : array;
import std.string : toLower, strip, indexOf;
import std.range : empty;
import std.conv : to;
import std.regex : regex, matchFirst;
import infrastructure.config.schema.schema : Target, TargetType, WorkspaceConfig;
import infrastructure.utils.logging;

/// Discovers test targets from workspace configuration
class TestDiscovery
{
    private WorkspaceConfig config;
    
    this(WorkspaceConfig config) @system
    {
        this.config = config;
    }
    
    /// Find all test targets
    Target[] findAll() @system
    {
        return config.targets
            .filter!(t => t.type == TargetType.Test)
            .array;
    }
    
    /// Find test targets matching a specific target ID
    Target[] findByTarget(string targetId) @system
    {
        if (targetId.empty)
            return findAll();
        
        // Exact match first
        auto exact = config.targets
            .filter!(t => t.type == TargetType.Test && t.name == targetId)
            .array;
        
        if (!exact.empty)
            return exact;
        
        // Pattern match (e.g., //path:target)
        return config.targets
            .filter!(t => t.type == TargetType.Test && matchesPattern(t.name, targetId))
            .array;
    }
    
    /// Find test targets matching a filter expression
    Target[] findByFilter(string filter) @system
    {
        if (filter.empty)
            return findAll();
        
        // Convert filter to lowercase for case-insensitive matching
        immutable filterLower = filter.toLower().strip();
        
        return config.targets
            .filter!(t => t.type == TargetType.Test && matchesFilter(t, filterLower))
            .array;
    }
    
    /// Check if target matches filter
    private bool matchesFilter(const Target target, string filterLower) @system
    {
        immutable nameLower = target.name.toLower();
        
        // Simple substring match on target name
        if (nameLower.canFind(filterLower))
            return true;
        
        // Check sources for matching patterns
        foreach (source; target.sources)
        {
            if (source.toLower().canFind(filterLower))
                return true;
        }
        
        return false;
    }
    
    /// Check if target name matches a pattern
    private bool matchesPattern(string name, string pattern) @system
    {
        // Support wildcards
        if (pattern == "//...")
            return true;
        
        // Support path-based matching
        if (pattern.startsWith("//"))
        {
            immutable pathPart = pattern[2 .. $];
            
            // Match "//path/..." pattern
            if (pathPart.endsWith("..."))
            {
                immutable prefix = pathPart[0 .. $ - 3];
                return name.canFind(prefix);
            }
            
            // Match "//path:*" pattern
            if (pathPart.canFind("*"))
            {
                immutable beforeStar = pathPart[0 .. pathPart.indexOf("*")];
                return name.startsWith("//" ~ beforeStar);
            }
        }
        
        // Simple contains match
        return name.canFind(pattern);
    }
    
    /// Get summary of test targets
    struct TestSummary
    {
        size_t totalTests;
        size_t[string] testsByLanguage;
    }
    
    TestSummary getSummary() @system
    {
        TestSummary summary;
        auto tests = findAll();
        summary.totalTests = tests.length;
        
        foreach (test; tests)
        {
            immutable lang = test.language.to!string;
            if (lang !in summary.testsByLanguage)
                summary.testsByLanguage[lang] = 0;
            summary.testsByLanguage[lang]++;
        }
        
        return summary;
    }
}

unittest
{
    import std.conv : to;
    
    // Test pattern matching
    WorkspaceConfig config;
    
    Target t1;
    t1.name = "//core:unit-test";
    t1.type = TargetType.Test;
    
    Target t2;
    t2.name = "//api:integration-test";
    t2.type = TargetType.Test;
    
    Target t3;
    t3.name = "//main";
    t3.type = TargetType.Executable;
    
    config.targets = [t1, t2, t3];
    
    auto discovery = new TestDiscovery(config);
    
    // Should find all test targets
    auto allTests = discovery.findAll();
    assert(allTests.length == 2);
    
    // Should filter by name
    auto filtered = discovery.findByFilter("unit");
    assert(filtered.length == 1);
    assert(filtered[0].name == "//core:unit-test");
}

