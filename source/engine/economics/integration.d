module engine.economics.integration;

import std.datetime : Duration, seconds;
import std.conv : to;
import std.string : toLower;
import engine.economics.pricing;
import engine.economics.optimizer;
import engine.economics.estimator;
import engine.economics.strategies;
import engine.economics.tracking;
import engine.economics.tracking : WorkerStartupSavings, trackWorkerSavings;
import engine.graph : BuildGraph;
import engine.distributed.coordinator.profile : ProfileGuidedScheduler, createProfiledScheduler;
import infrastructure.config.schema.schema : EconomicsConfig;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// Economic optimizer integration with build system
/// Wraps optimizer with configuration and provides simple API
/// Supports profile-guided action scheduling for critical-path optimization
final class EconomicsIntegration
{
    private CostOptimizer optimizer;
    private CostTracker tracker;
    private CostEstimator estimator;
    private ExecutionHistory history;
    private PricingConfig pricingConfig;
    private bool enabled;
    private WorkerStartupSavings workerSavings;
    
    this(EconomicsConfig config, string cacheDir) @trusted
    {
        this.enabled = config.enabled;
        if (!enabled) return;
        
        this.pricingConfig = PricingConfig();
        this.pricingConfig.enabled = true;
        
        // Set cloud provider
        this.pricingConfig.provider = ({
            switch (config.provider.toLower) {
                case "aws": return CloudProvider.aws();
                case "gcp": return CloudProvider.gcp();
                case "azure": return CloudProvider.azure();
                case "local": return CloudProvider.local();
                default: return CloudProvider.aws();
            }
        })();
        
        // Set pricing tier
        this.pricingConfig.profile = ({
            switch (config.pricingTier.toLower) {
                case "spot": return PricingProfile.spot;
                case "ondemand", "on-demand": return PricingProfile.onDemand;
                case "reserved": return PricingProfile.reserved;
                case "premium": return PricingProfile.premium;
                default: return PricingProfile.onDemand;
            }
        })();
        
        this.history = new ExecutionHistory();
        this.tracker = new CostTracker(history, cacheDir);
        
        auto loadResult = tracker.load();
        if (loadResult.isErr)
            Logger.warning("Could not load execution history: " ~ loadResult.unwrapErr().message());
        
        this.estimator = new CostEstimator(history);
        this.optimizer = new CostOptimizer(estimator, pricingConfig);
        
        Logger.info("Economic optimizer initialized");
        Logger.info("  Provider: " ~ pricingConfig.provider.name);
        Logger.info("  Tier: " ~ pricingConfig.profile.tier.to!string);
    }
    
    /// Check if economics is enabled
    bool isEnabled() const pure @safe nothrow @nogc => enabled;
    
    /// Compute optimal build plan for graph
    BuildResult!BuildPlan computePlan(BuildGraph graph, EconomicsConfig config) @trusted
    {
        if (!enabled)
            return Ok!(BuildPlan, BuildError)(BuildPlan(StrategyConfig(ExecutionStrategy.Local, 1, 4), seconds(0), 0.0f));
        
        OptimizationConstraints constraints;
        
        constraints.objective = ({
            switch (config.optimize.toLower) {
                case "cost": return OptimizationObjective.MinimizeCost;
                case "time": return OptimizationObjective.MinimizeTime;
                case "balanced": return OptimizationObjective.Balanced;
                default: return OptimizationObjective.Balanced;
            }
        })();
        
        constraints.budgetUSD = config.budgetUSD;
        if (config.timeLimit != float.infinity)
            constraints.timeLimit = seconds(cast(long)config.timeLimit);
        
        // If budget or time limit specified, override objective
        if (config.budgetUSD != float.infinity)
            constraints.objective = OptimizationObjective.Budget;
        else if (config.timeLimit != float.infinity)
            constraints.objective = OptimizationObjective.TimeLimit;
        
        return optimizer.optimize(graph, constraints);
    }
    
    /// Get cost tracker for recording actual costs
    CostTracker getTracker() @safe nothrow @nogc => tracker;
    
    /// Get execution history for profile-guided scheduling
    ExecutionHistory getExecutionHistory() @safe nothrow @nogc => history;
    
    /// Get cost estimator for action profiling
    CostEstimator getCostEstimator() @safe nothrow @nogc => estimator;
    
    /// Create profile-guided scheduler for a build graph
    /// Uses historical execution data for critical-path scheduling
    ProfileGuidedScheduler createProfileScheduler(BuildGraph graph) @trusted
    {
        if (!enabled || history is null)
            return null;
        
        auto scheduler = createProfiledScheduler(graph, history);
        Logger.debugLog("Created profile-guided scheduler with economic data");
        return scheduler;
    }
    
    /// Track worker startup savings from persistent worker pool
    void trackWorkerStartupSavings(string workerType, bool usedWarm, long savedMs) @safe
    {
        if (!enabled) return;
        trackWorkerSavings(workerSavings, workerType, usedWarm, savedMs);
    }
    
    /// Get accumulated worker startup savings
    WorkerStartupSavings getWorkerSavings() const @safe nothrow @nogc => workerSavings;
    
    /// Display plan to user
    void displayPlan(const BuildPlan plan) const @trusted
    {
        import std.stdio : writeln;
        
        if (!enabled)
            return;
        
        writeln("\n" ~ "━".repeat(60).to!string);
        writeln("Economic Build Plan");
        writeln("━".repeat(60).to!string);
        writeln(formatPlan(plan));
        writeln("━".repeat(60).to!string ~ "\n");
    }
    
    /// Save execution history on shutdown
    VoidBuildResult shutdown() @trusted
    {
        if (!enabled) return Ok!BuildError();
        
        Logger.info("\n" ~ tracker.getSummary().format());
        
        // Display worker startup savings if any
        if (workerSavings.warmExecutions > 0)
            Logger.info("\n" ~ workerSavings.format());
        
        return tracker.save();
    }
}

/// Helper: repeat string N times
private string repeat(string s, size_t n) pure @safe
{
    import std.array : join, array;
    import std.range : iota;
    import std.algorithm : map;
    
    return iota(n).map!(_ => s).join;
}

