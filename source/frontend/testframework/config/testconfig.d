module frontend.testframework.config.testconfig;

import std.file : exists, readText;
import std.json : parseJSON, JSONValue, JSONType;
import std.conv : to;
import frontend.testframework.execution : TestExecutionConfig, TestExecutionMode;
import frontend.testframework.sharding : ShardStrategy;
import frontend.testframework.flaky : RetryPolicy;
import infrastructure.utils.logging;

/// Test framework configuration
/// Can be loaded from .buildertest file or specified via CLI
struct BuilderTestConfig
{
    // Execution
    bool parallel = true;
    size_t jobs = 0;                    // 0 = auto-detect
    
    // Sharding
    bool shard = true;                  // Enable sharding by default
    size_t shardCount = 0;              // 0 = auto
    string shardStrategy = "adaptive";  // adaptive, content, round-robin
    
    // Caching
    bool cache = true;
    string cacheDir = ".builder-cache/tests";
    size_t cacheMaxAge = 30;            // days
    bool hermetic = true;               // Verify environment
    
    // Retry & Flaky Detection
    bool retry = true;
    size_t maxRetries = 3;
    bool detectFlaky = true;
    bool quarantineFlaky = true;
    bool skipQuarantined = false;
    
    // Reporting
    bool analytics = false;             // Disabled by default
    bool verbose = false;
    bool showPassed = false;
    bool failFast = false;
    
    // Output
    bool junit = false;
    string junitPath = "test-results.xml";
    
    /// Load configuration from .buildertest file
    static BuilderTestConfig load(string path = ".buildertest") @system
    {
        BuilderTestConfig config;
        
        if (!exists(path))
        {
            structuredLog.debug_("no_buildertest_config_found_using_defaul").emit();
            return config;
        }
        
        try
        {
            auto content = readText(path);
            auto json = parseJSON(content);
            
            // Execution
            if ("parallel" in json)
                config.parallel = json["parallel"].type == JSONType.true_;
            if ("jobs" in json)
                config.jobs = json["jobs"].integer.to!size_t;
            
            // Sharding
            if ("shard" in json)
                config.shard = json["shard"].type == JSONType.true_;
            if ("shardCount" in json)
                config.shardCount = json["shardCount"].integer.to!size_t;
            if ("shardStrategy" in json)
                config.shardStrategy = json["shardStrategy"].str;
            
            // Caching
            if ("cache" in json)
                config.cache = json["cache"].type == JSONType.true_;
            if ("cacheDir" in json)
                config.cacheDir = json["cacheDir"].str;
            if ("cacheMaxAge" in json)
                config.cacheMaxAge = json["cacheMaxAge"].integer.to!size_t;
            if ("hermetic" in json)
                config.hermetic = json["hermetic"].type == JSONType.true_;
            
            // Retry
            if ("retry" in json)
                config.retry = json["retry"].type == JSONType.true_;
            if ("maxRetries" in json)
                config.maxRetries = json["maxRetries"].integer.to!size_t;
            if ("detectFlaky" in json)
                config.detectFlaky = json["detectFlaky"].type == JSONType.true_;
            if ("quarantineFlaky" in json)
                config.quarantineFlaky = json["quarantineFlaky"].type == JSONType.true_;
            if ("skipQuarantined" in json)
                config.skipQuarantined = json["skipQuarantined"].type == JSONType.true_;
            
            // Reporting
            if ("analytics" in json)
                config.analytics = json["analytics"].type == JSONType.true_;
            if ("verbose" in json)
                config.verbose = json["verbose"].type == JSONType.true_;
            if ("showPassed" in json)
                config.showPassed = json["showPassed"].type == JSONType.true_;
            if ("failFast" in json)
                config.failFast = json["failFast"].type == JSONType.true_;
            
            // Output
            if ("junit" in json)
                config.junit = json["junit"].type == JSONType.true_;
            if ("junitPath" in json)
                config.junitPath = json["junitPath"].str;
            
            structuredLog.info("loaded_test_configuration_from_").field("detail", "Loaded test configuration from " ~ path).emit();
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_load_buildertest_").field("detail", "Failed to load .buildertest: " ~ e.msg).emit();
        }
        
        return config;
    }
    
    /// Convert to execution config
    TestExecutionConfig toExecutionConfig() const pure nothrow @safe
    {
        TestExecutionConfig execConfig;
        
        // Set execution mode
        if (!parallel)
            execConfig.mode = TestExecutionMode.Sequential;
        else if (shard)
            execConfig.mode = TestExecutionMode.Sharded;
        else
            execConfig.mode = TestExecutionMode.Parallel;
        
        execConfig.maxParallelism = jobs;
        execConfig.shardCount = shardCount;
        
        // Caching
        execConfig.enableCaching = cache;
        execConfig.cacheConfig.hermetic = hermetic;
        
        // Retry
        execConfig.enableRetry = retry;
        execConfig.retryPolicy.maxAttempts = maxRetries;
        execConfig.enableFlakyDetection = detectFlaky;
        execConfig.skipQuarantined = skipQuarantined;
        
        // Sharding
        execConfig.enableSharding = shard;
        
        // Map shard strategy
        switch (shardStrategy)
        {
            case "adaptive":
                execConfig.shardConfig.strategy = ShardStrategy.Adaptive;
                break;
            case "content":
                execConfig.shardConfig.strategy = ShardStrategy.ContentBased;
                break;
            case "round-robin":
                execConfig.shardConfig.strategy = ShardStrategy.RoundRobin;
                break;
            case "load":
                execConfig.shardConfig.strategy = ShardStrategy.LoadBased;
                break;
            default:
                execConfig.shardConfig.strategy = ShardStrategy.Adaptive;
        }
        
        if (shardCount > 0)
            execConfig.shardConfig.shardCount = shardCount;
        
        return execConfig;
    }
    
    /// Generate example .buildertest file
    static string generateExample() pure @safe
    {
        return `{
  // Execution settings
  "parallel": true,
  "jobs": 0,  // 0 = auto-detect CPU count
  
  // Sharding (parallel test distribution)
  "shard": true,
  "shardCount": 0,  // 0 = auto-calculate optimal
  "shardStrategy": "adaptive",  // adaptive | content | round-robin | load
  
  // Caching (skip unchanged tests)
  "cache": true,
  "cacheDir": ".builder-cache/tests",
  "cacheMaxAge": 30,  // days
  "hermetic": true,   // Verify environment hasn't changed
  
  // Retry & Flaky Detection
  "retry": true,
  "maxRetries": 3,
  "detectFlaky": true,
  "quarantineFlaky": true,
  "skipQuarantined": false,
  
  // Reporting
  "analytics": false,
  "verbose": false,
  "showPassed": false,
  "failFast": false,
  
  // Output formats
  "junit": false,
  "junitPath": "test-results.xml"
}
`;
    }
}

