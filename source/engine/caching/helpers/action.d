module engine.caching.helpers.action;

import std.datetime : Duration, dur;
import std.datetime.stopwatch : StopWatch, AutoStart;
import engine.caching.actions.action : ActionCache, ActionId, ActionType;
import engine.caching.coordinator : CacheCoordinator;
import infrastructure.errors;

/// Helper for action cache integration in language handlers
/// Provides simple API for checking and recording actions
struct ActionCacheHelper
{
    private CacheCoordinator coordinator;
    private ActionCache cache;
    
    /// Create helper with coordinator (recommended)
    static ActionCacheHelper withCoordinator(CacheCoordinator coordinator) @safe
    {
        ActionCacheHelper helper;
        helper.coordinator = coordinator;
        return helper;
    }
    
    /// Create helper with direct cache (legacy)
    static ActionCacheHelper withCache(ActionCache cache) @safe
    {
        ActionCacheHelper helper;
        helper.cache = cache;
        return helper;
    }
    
    /// Check if action is cached
    bool isCached(
        ActionId actionId,
        scope const(string)[] inputs,
        scope const(string[string]) metadata
    ) @system
    {
        if (coordinator !is null)
            return coordinator.isActionCached(actionId, inputs, metadata);
        else if (cache !is null)
            return cache.isCached(actionId, inputs, metadata);
        
        return false;
    }
    
    /// Record action result
    void record(
        ActionId actionId,
        scope const(string)[] inputs,
        scope const(string)[] outputs,
        scope const(string[string]) metadata,
        bool success
    ) @system
    {
        if (coordinator !is null)
            coordinator.recordAction(actionId, inputs, outputs, metadata, success);
        else if (cache !is null)
            cache.update(actionId, inputs, outputs, metadata, success);
    }
}

/// Mixin template for easy action cache integration
/// Usage: mixin ActionCacheIntegration!"myhandler";
mixin template ActionCacheIntegration(string handlerName)
{
    import engine.caching.helpers.action : ActionCacheHelper;
    import engine.caching.actions.action : ActionId, ActionType;
    import infrastructure.utils.files.hash : FastHash;
    
    private ActionCacheHelper actionHelper;
    private string[][ActionId] trackedOutputs;  // Track outputs per action
    
    /// Initialize action cache helper
    protected void initActionCache(ActionCacheHelper helper) @system
    {
        this.actionHelper = helper;
    }
    
    /// Track output file for current action
    protected void trackOutput(ActionId actionId, string outputPath) @system
    {
        trackedOutputs[actionId] ~= outputPath;
    }
    
    /// Track multiple output files for current action
    protected void trackOutputs(ActionId actionId, scope const(string)[] outputPaths) @system
    {
        foreach (path; outputPaths)
            trackedOutputs[actionId] ~= path;
    }
    
    /// Check and execute action with caching
    protected BuildResult!string withActionCache(
        string targetName,
        ActionType actionType,
        string subId,
        scope const(string)[] inputs,
        scope const(string[string]) metadata,
        BuildResult!string delegate() @system action
    ) @system
    {
        import std.file : exists;
        
        // Compute input hash
        string inputHash;
        try
        {
            if (inputs.length > 0 && exists(inputs[0]))
                inputHash = FastHash.hashFile(inputs[0]);
            else
                inputHash = "empty";
        }
        catch (Exception)
        {
            inputHash = "error";
        }
        
        // Create action ID
        auto actionId = ActionId(targetName, actionType, inputHash, subId);
        
        // Check cache
        if (actionHelper.isCached(actionId, inputs, metadata))
        {
            // Return empty success (outputs already exist)
            return Ok!(string, BuildError)("cached");
        }
        
        // Clear any previously tracked outputs for this action
        trackedOutputs.remove(actionId);
        
        // Execute action
        auto result = action();
        
        // Retrieve tracked outputs
        string[] outputs;
        if (auto outputsPtr = actionId in trackedOutputs)
            outputs = *outputsPtr;
        
        // Record result with tracked outputs
        actionHelper.record(actionId, inputs, outputs, metadata, result.isOk);
        
        // Clean up tracked outputs
        trackedOutputs.remove(actionId);
        
        return result;
    }
    
    /// Enhanced version with explicit output specification
    protected BuildResult!(string[]) withActionCacheAndOutputs(
        string targetName,
        ActionType actionType,
        string subId,
        scope const(string)[] inputs,
        scope const(string[string]) metadata,
        BuildResult!(string[]) delegate() @system action
    ) @system
    {
        import std.file : exists;
        
        // Compute input hash
        string inputHash;
        try
        {
            if (inputs.length > 0 && exists(inputs[0]))
                inputHash = FastHash.hashFile(inputs[0]);
            else
                inputHash = "empty";
        }
        catch (Exception)
        {
            inputHash = "error";
        }
        
        // Create action ID
        auto actionId = ActionId(targetName, actionType, inputHash, subId);
        
        // Check cache
        if (actionHelper.isCached(actionId, inputs, metadata))
        {
            // Retrieve cached outputs
            if (auto outputsPtr = actionId in trackedOutputs)
                return Ok!(string[], BuildError)(*outputsPtr);
            return Ok!(string[], BuildError)([]);
        }
        
        // Execute action
        auto result = action();
        
        if (result.isOk)
        {
            // Record result with explicit outputs
            auto outputs = result.unwrap();
            actionHelper.record(actionId, inputs, outputs, metadata, true);
        }
        else
        {
            // Record failure
            actionHelper.record(actionId, inputs, [], metadata, false);
        }
        
        return result;
    }
}

/// Result container for actions with output tracking
struct ActionResult(T)
{
    T value;
    string[] outputs;
    
    static ActionResult!T ok(T value, string[] outputs = []) @safe pure nothrow
    {
        return ActionResult!T(value, outputs);
    }
}

