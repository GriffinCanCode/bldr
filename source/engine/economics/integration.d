module engine.economics.integration;

import std.datetime : Duration, seconds;
import std.conv : to;
import std.string : toLower;
import engine.economics.pricing;
import engine.economics.optimizer;
import engine.economics.estimator;
import engine.economics.strategies;
import engine.economics.tracking;
import engine.graph : BuildGraph;
import infrastructure.config.schema.schema : EconomicsConfig;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// Economic optimizer integration with build system
/// Wraps optimizer with configuration and provides simple API
final class EconomicsIntegration
{
    private CostOptimizer optimizer;
    private CostTracker tracker;
    private PricingConfig pricingConfig;
    private bool enabled;
    
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
        
        auto history = new ExecutionHistory();
        this.tracker = new CostTracker(history, cacheDir);
        
        auto loadResult = tracker.load();
        if (loadResult.isErr)
            Logger.warning("Could not load execution history: " ~ loadResult.unwrapErr().message());
        
        auto estimator = new CostEstimator(history);
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

