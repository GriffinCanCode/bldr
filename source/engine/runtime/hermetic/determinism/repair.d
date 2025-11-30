module engine.runtime.hermetic.determinism.repair;

import std.algorithm : sort, uniq, map;
import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.string : indexOf;
import engine.runtime.hermetic.determinism.detector;
import engine.runtime.hermetic.determinism.enforcer;

/// Repair suggestion for non-determinism
struct RepairSuggestion
{
    int priority;                 // 1=critical, 2=high, 3=medium, 4=low
    string title;                // Short title
    string description;          // Detailed description
    string[] compilerFlags;      // Compiler flags to add
    string[] envVars;            // Environment variables to set
    string[] builderfileChanges; // Changes to Builderfile
    string[] references;         // Documentation links
    
    /// Format as human-readable string with ANSI colors
    string format() const @safe
    {
        import std.string : join;
        
        string result;
        
        // Priority icon
        string icon = getPriorityIcon(priority);
        result ~= icon ~ " " ~ getPriorityLabel(priority) ~ ": " ~ title ~ "\n\n";
        
        // Description
        result ~= "  " ~ description ~ "\n\n";
        
        // Compiler flags
        if (compilerFlags.length > 0)
        {
            result ~= "  Compiler flags to add:\n";
            foreach (flag; compilerFlags)
                result ~= "    " ~ flag ~ "\n";
            result ~= "\n";
        }
        
        // Environment variables
        if (envVars.length > 0)
        {
            result ~= "  Environment variables to set:\n";
            foreach (envVar; envVars)
                result ~= "    export " ~ envVar ~ "\n";
            result ~= "\n";
        }
        
        // Builderfile changes
        if (builderfileChanges.length > 0)
        {
            result ~= "  Builderfile changes:\n";
            foreach (change; builderfileChanges)
                result ~= "    " ~ change ~ "\n";
            result ~= "\n";
        }
        
        // References
        if (references.length > 0)
        {
            result ~= "  References:\n";
            foreach (ref_; references)
                result ~= "    • " ~ ref_ ~ "\n";
        }
        
        return result;
    }
    
    private:
    
    static string getPriorityIcon(int priority) pure @safe nothrow
    {
        switch (priority)
        {
            case 1: return "🔴";
            case 2: return "🟠";
            case 3: return "🟡";
            case 4: return "🔵";
            default: return "⚪";
        }
    }
    
    static string getPriorityLabel(int priority) pure @safe nothrow
    {
        switch (priority)
        {
            case 1: return "CRITICAL";
            case 2: return "HIGH";
            case 3: return "MEDIUM";
            case 4: return "LOW";
            default: return "INFO";
        }
    }
}

/// Repair plan for determinism issues
struct RepairPlan
{
    RepairSuggestion[] suggestions;
    int totalIssues;
    int criticalIssues;
    
    /// Format as complete repair plan
    string format() const @safe
    {
        string result;
        
        result ~= "╔══════════════════════════════════════════════════════════════╗\n";
        result ~= "║        Determinism Repair Plan                               ║\n";
        result ~= "╚══════════════════════════════════════════════════════════════╝\n\n";
        
        result ~= .format("Found %d issues (%d critical)\n\n", totalIssues, criticalIssues);
        
        foreach (i, suggestion; suggestions)
        {
            result ~= .format("Issue %d/%d:\n", i + 1, suggestions.length);
            result ~= suggestion.format();
            result ~= "\n" ~ "─".repeat(60).array.to!string ~ "\n\n";
        }
        
        result ~= "Next steps:\n";
        result ~= "  1. Apply the suggested compiler flags to your build\n";
        result ~= "  2. Set the environment variables before building\n";
        result ~= "  3. Update your Builderfile with the recommended changes\n";
        result ~= "  4. Run `builder verify-determinism <target>` to verify\n";
        
        return result;
    }
}

/// Repair engine for generating fix suggestions
struct RepairEngine
{
    /// Generate repair suggestions from detections
    static RepairSuggestion[] generateSuggestions(Detection[] detections) @safe
    {
        RepairSuggestion[] suggestions;
        
        foreach (detection; detections)
        {
            RepairSuggestion suggestion;
            suggestion.priority = detection.priority;
            suggestion.description = detection.description;
            suggestion.compilerFlags = detection.compilerFlags;
            suggestion.envVars = detection.envVars;
            suggestion.references = detection.references;
            
            // Generate title based on source
            final switch (detection.source)
            {
                case NonDeterminismSource.Timestamp:
                    suggestion.title = "Timestamp Embedding";
                    break;
                case NonDeterminismSource.RandomValue:
                    suggestion.title = "Random Values";
                    break;
                case NonDeterminismSource.ThreadScheduling:
                    suggestion.title = "Thread Scheduling";
                    break;
                case NonDeterminismSource.BuildPath:
                    suggestion.title = "Build Path Leakage";
                    break;
                case NonDeterminismSource.CompilerNonDet:
                    suggestion.title = "Compiler Non-Determinism";
                    break;
                case NonDeterminismSource.FileOrdering:
                    suggestion.title = "File System Ordering";
                    break;
                case NonDeterminismSource.PointerAddress:
                    suggestion.title = "Pointer Addresses";
                    break;
                case NonDeterminismSource.OutputMismatch:
                    suggestion.title = "Output Mismatch";
                    break;
                case NonDeterminismSource.Unknown:
                    suggestion.title = "Unknown Source";
                    break;
            }
            
            suggestions ~= suggestion;
        }
        
        return suggestions;
    }
    
    /// Generate complete repair plan
    static RepairPlan generateRepairPlan(
        Detection[] detections,
        DeterminismViolation[] violations
    ) @safe
    {
        RepairPlan plan;
        
        // Generate suggestions from detections
        auto detectionSuggestions = generateSuggestions(detections);
        
        // Generate suggestions from violations
        auto violationSuggestions = generateSuggestionsFromViolations(violations);
        
        // Combine and deduplicate
        plan.suggestions = (detectionSuggestions ~ violationSuggestions)
            .sort!((a, b) => a.priority < b.priority)
            .array;
        
        plan.totalIssues = cast(int)plan.suggestions.length;
        plan.criticalIssues = cast(int)plan.suggestions
            .map!(s => s.priority == 1 ? 1 : 0)
            .sum;
        
        return plan;
    }
    
    /// Generate consolidated compiler flags
    static string[] generateConsolidatedFlags(Detection[] detections) @safe
    {
        return detections
            .map!(d => d.compilerFlags)
            .join
            .sort
            .uniq
            .array;
    }
    
    /// Generate consolidated environment variables
    static string[string] generateConsolidatedEnvVars(Detection[] detections) @safe
    {
        string[string] envVars;
        
        foreach (detection; detections)
        {
            foreach (envVar; detection.envVars)
            {
                // Parse KEY=VALUE format
                auto eqIndex = envVar.indexOf('=');
                if (eqIndex > 0)
                {
                    auto key = envVar[0..eqIndex];
                    auto value = envVar[eqIndex+1..$];
                    envVars[key] = value;
                }
                else
                {
                    envVars[envVar] = "";
                }
            }
        }
        
        return envVars;
    }
    
    private:
    
    /// Generate suggestions from violations
    static RepairSuggestion[] generateSuggestionsFromViolations(
        DeterminismViolation[] violations
    ) @safe
    {
        RepairSuggestion[] suggestions;
        
        foreach (violation; violations)
        {
            RepairSuggestion suggestion;
            suggestion.title = violation.source;
            suggestion.description = violation.description;
            suggestion.priority = 2;
            
            // Parse suggestion for actionable items
            if (violation.suggestion.length > 0)
            {
                suggestion.builderfileChanges = [violation.suggestion];
            }
            
            suggestions ~= suggestion;
        }
        
        return suggestions;
    }
}

/// Helper for std.algorithm.sum
private auto sum(R)(R range)
{
    int total = 0;
    foreach (item; range)
        total += item;
    return total;
}

/// Helper for repeat (simple implementation)
private struct Repeat
{
    string str;
    size_t count;
    
    auto array() const
    {
        import std.array : appender;
        auto result = appender!string;
        foreach (_; 0..count)
            result ~= str;
        return result[];
    }
}

private auto repeat(string str, size_t count)
{
    return Repeat(str, count);
}

@safe unittest
{
    import std.stdio : writeln;
    
    writeln("Testing repair engine...");
    
    // Create test detection
    Detection detection;
    detection.source = NonDeterminismSource.RandomValue;
    detection.description = "Test detection";
    detection.compilerFlags = ["-frandom-seed=42"];
    detection.priority = 1;
    
    // Generate suggestions
    auto suggestions = RepairEngine.generateSuggestions([detection]);
    assert(suggestions.length == 1);
    assert(suggestions[0].title == "Random Values");
    assert(suggestions[0].compilerFlags.length == 1);
    
    // Generate repair plan
    DeterminismViolation violation;
    violation.source = "test";
    violation.description = "Test violation";
    
    auto plan = RepairEngine.generateRepairPlan([detection], [violation]);
    assert(plan.suggestions.length == 2);
    
    writeln("✓ Repair engine tests passed");
}
