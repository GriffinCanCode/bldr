module tests.unit.caching.index_test;

import engine.caching.index;
import std.datetime : Clock, SysTime;
import std.file : exists, rmdirRecurse, mkdirRecurse;
import std.path : buildPath;

/// Test CacheIndex SQLite functionality
@("CacheIndex: basic target operations")
unittest
{
    auto testDir = ".test-cache-index";
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto index = new CacheIndex(testDir);
    scope(exit) index.close();
    
    // Initially empty
    assert(!index.hasTarget("test-target"));
    assert(index.listTargets().length == 0);
    
    // Put target
    TargetIndexEntry entry;
    entry.key = "test-target";
    entry.contentHash = "abc123";
    entry.metadataHash = "meta456";
    entry.size = 1024;
    entry.sourceCount = 3;
    entry.depCount = 2;
    
    index.putTarget(entry);
    
    // Verify target exists
    assert(index.hasTarget("test-target"));
    
    // Get target
    auto result = index.getTarget("test-target");
    assert(result.isOk);
    auto retrieved = result.unwrap();
    assert(retrieved.key == "test-target");
    assert(retrieved.contentHash == "abc123");
    assert(retrieved.size == 1024);
    
    // List targets
    auto targets = index.listTargets();
    assert(targets.length == 1);
    assert(targets[0] == "test-target");
}

@("CacheIndex: target LRU tracking")
unittest
{
    auto testDir = ".test-cache-index-lru";
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto index = new CacheIndex(testDir);
    scope(exit) index.close();
    
    // Add multiple targets
    foreach (i; 0 .. 5)
    {
        TargetIndexEntry entry;
        entry.key = "target-" ~ i.to!string;
        entry.contentHash = "hash" ~ i.to!string;
        entry.size = 100;
        index.putTarget(entry);
    }
    
    // Touch target-2 to make it recently accessed
    index.touchTarget("target-2");
    
    // Select for eviction (keep 3)
    auto toEvict = index.selectTargetEvictions(3, size_t.max, 365);
    
    // Should evict 2 oldest (not target-2 which was touched)
    assert(toEvict.length == 2);
}

@("CacheIndex: action operations")
unittest
{
    auto testDir = ".test-cache-index-actions";
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto index = new CacheIndex(testDir);
    scope(exit) index.close();
    
    // Add actions
    ActionIndexEntry action1;
    action1.key = "target1:Compile:hash1";
    action1.targetId = "target1";
    action1.actionType = 0;  // Compile
    action1.contentHash = "exec-hash-1";
    action1.size = 500;
    action1.success = true;
    action1.inputCount = 3;
    action1.outputCount = 1;
    
    index.putAction(action1);
    
    ActionIndexEntry action2;
    action2.key = "target1:Link:hash2";
    action2.targetId = "target1";
    action2.actionType = 1;  // Link
    action2.contentHash = "exec-hash-2";
    action2.size = 200;
    action2.success = true;
    action2.inputCount = 1;
    action2.outputCount = 1;
    
    index.putAction(action2);
    
    // Get actions for target
    auto actionsForTarget = index.getActionsForTarget("target1");
    assert(actionsForTarget.length == 2);
    
    // List all actions
    auto allActions = index.listActions();
    assert(allActions.length == 2);
}

@("CacheIndex: statistics tracking")
unittest
{
    auto testDir = ".test-cache-index-stats";
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto index = new CacheIndex(testDir);
    scope(exit) index.close();
    
    // Record hits/misses
    index.recordTargetHit();
    index.recordTargetHit();
    index.recordTargetMiss();
    
    index.recordActionHit();
    index.recordActionMiss();
    index.recordActionMiss();
    
    // Get stats
    auto targetStats = index.getTargetStats();
    assert(targetStats.hits == 2);
    assert(targetStats.misses == 1);
    
    auto actionStats = index.getActionStats();
    assert(actionStats.hits == 1);
    assert(actionStats.misses == 2);
}

@("CacheIndex: query by pattern")
unittest
{
    auto testDir = ".test-cache-index-query";
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto index = new CacheIndex(testDir);
    scope(exit) index.close();
    
    // Add targets with different patterns
    foreach (name; ["frontend/app", "frontend/utils", "backend/api", "backend/db"])
    {
        TargetIndexEntry entry;
        entry.key = name;
        entry.contentHash = "hash";
        entry.size = 100;
        index.putTarget(entry);
    }
    
    // Query by pattern
    auto frontendTargets = index.queryTargets("frontend");
    assert(frontendTargets.length == 2);
    
    auto backendTargets = index.queryTargets("backend");
    assert(backendTargets.length == 2);
    
    auto apiTargets = index.queryTargets("api");
    assert(apiTargets.length == 1);
}

@("CacheIndex: clear and total count")
unittest
{
    auto testDir = ".test-cache-index-clear";
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto index = new CacheIndex(testDir);
    scope(exit) index.close();
    
    // Add entries
    foreach (i; 0 .. 3)
    {
        TargetIndexEntry t;
        t.key = "target-" ~ i.to!string;
        t.contentHash = "hash";
        t.size = 100;
        index.putTarget(t);
        
        ActionIndexEntry a;
        a.key = "action-" ~ i.to!string;
        a.targetId = "target-" ~ i.to!string;
        a.contentHash = "hash";
        a.size = 50;
        index.putAction(a);
    }
    
    assert(index.totalEntryCount() == 6);
    
    // Clear
    index.clear();
    
    assert(index.totalEntryCount() == 0);
    assert(index.listTargets().length == 0);
    assert(index.listActions().length == 0);
}

@("CacheIndex: delete operations")
unittest
{
    auto testDir = ".test-cache-index-delete";
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto index = new CacheIndex(testDir);
    scope(exit) index.close();
    
    // Add target
    TargetIndexEntry entry;
    entry.key = "to-delete";
    entry.contentHash = "hash";
    entry.size = 100;
    index.putTarget(entry);
    
    assert(index.hasTarget("to-delete"));
    
    // Delete
    index.deleteTarget("to-delete");
    
    assert(!index.hasTarget("to-delete"));
    
    // Add action
    ActionIndexEntry action;
    action.key = "action-to-delete";
    action.targetId = "target";
    action.contentHash = "hash";
    action.size = 50;
    index.putAction(action);
    
    assert(index.hasAction("action-to-delete"));
    
    // Delete
    index.deleteAction("action-to-delete");
    
    assert(!index.hasAction("action-to-delete"));
}

private string to(T)(T val) pure @safe
{
    import std.conv : to;
    return std.conv.to!string(val);
}

