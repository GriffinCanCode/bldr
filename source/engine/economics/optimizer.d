module engine.economics.optimizer;

import std.datetime : Duration, seconds;
import std.algorithm : map, sort, filter;
import std.array : array, replace;
import std.conv : to;
import engine.economics.pricing;
import engine.economics.strategies;
import engine.economics.estimator;
import engine.graph : BuildGraph, BuildNode;
import infrastructure.errors;
import infrastructure.utils.logging;

/// Optimization objective
enum OptimizationObjective : ubyte
{
    MinimizeCost,      // Find cheapest build
    MinimizeTime,      // Find fastest build
    Balanced,          // Balance cost and time
    Budget,            // Fastest build within budget
    TimeLimit          // Cheapest build within time limit
}

/// Optimization constraints
struct OptimizationConstraints
{
    OptimizationObjective objective = OptimizationObjective.Balanced;
    float budgetUSD = float.infinity;           // Budget constraint
    Duration timeLimit = Duration.max;          // Time constraint
    float alpha = 0.5f;                         // Cost-time tradeoff (0=cost, 1=time)
    size_t maxWorkers = 64;                     // Maximum workers available
}

/// Cost optimizer - computes optimal build plans
final class CostOptimizer
{
    private CostEstimator estimator;
    private PricingConfig pricingConfig;
    private StrategyEnumerator enumerator;
    
    this(CostEstimator estimator, PricingConfig pricingConfig) @safe
    {
        this.estimator = estimator;
        this.pricingConfig = pricingConfig;
        this.enumerator = new StrategyEnumerator();
    }
    
    /// Optimize build plan for entire graph
    BuildResult!BuildPlan optimize(BuildGraph graph, OptimizationConstraints constraints) @trusted
    {
        structuredLog.info("computing_optimal_build_plan").emit();
        
        auto baselineResult = estimator.estimateGraph(graph);
        if (baselineResult.isErr)
            return Err!(BuildPlan, BuildError)(baselineResult.unwrapErr());
        
        auto baseline = baselineResult.unwrap();
        structuredLog.debug_("baseline_estimate_").field("detail", "Baseline estimate: " ~ formatDuration(baseline.duration) ~ " (cost: " ~ formatCost(0.0f) ~ ")").emit();
        
        immutable cacheHitProb = estimator.estimateCacheHitProbability(graph);
        structuredLog.debug_("cache_hit_probability_").field("detail", "Cache hit probability: " ~ (cacheHitProb * 100).to!int.to!string ~ "%").emit();
        
        auto candidates = enumerator.enumerate(baseline.duration, baseline.usage, cacheHitProb, pricingConfig.effectivePricing());
        structuredLog.debug_("generated_").field("detail", "Generated " ~ candidates.length.to!string ~ " candidate plans").emit();
        
        auto pareto = ParetoFrontier.compute(candidates);
        structuredLog.debug_("pareto_frontier_").field("detail", "Pareto frontier: " ~ pareto.plans.length.to!string ~ " optimal plans").emit();
        
        BuildPlan selectedPlan;
        
        final switch (constraints.objective)
        {
            case OptimizationObjective.MinimizeCost:
                selectedPlan = pareto.optimizeForCost();
                structuredLog.info("selected_minimize_cost").emit();
                break;
            case OptimizationObjective.MinimizeTime:
                selectedPlan = pareto.optimizeForTime();
                structuredLog.info("selected_minimize_time").emit();
                break;
            case OptimizationObjective.Balanced:
                selectedPlan = pareto.optimizeBalanced();
                structuredLog.info("selected_balanced_optimization").emit();
                break;
            case OptimizationObjective.Budget:
                if (constraints.budgetUSD == float.infinity)
                    return Err!(BuildPlan, BuildError)(new EconomicsError("Budget constraint specified but no budget provided"));
                selectedPlan = pareto.findWithinBudget(constraints.budgetUSD);
                structuredLog.info("selected_fastest_within_").field("detail", "Selected: Fastest within $" ~ constraints.budgetUSD.to!string).emit();
                break;
            case OptimizationObjective.TimeLimit:
                if (constraints.timeLimit == Duration.max)
                    return Err!(BuildPlan, BuildError)(new EconomicsError("Time limit constraint specified but no limit provided"));
                selectedPlan = pareto.findWithinTime(constraints.timeLimit);
                structuredLog.info("selected_cheapest_within_").field("detail", "Selected: Cheapest within " ~ formatDuration(constraints.timeLimit)).emit();
                break;
        }
        
        structuredLog.info("optimized_build_plan").emit();
        structuredLog.info("__").field("detail", "  " ~ formatPlan(selectedPlan).replace("\n", "\n  ")).emit();
        
        return Ok!(BuildPlan, BuildError)(selectedPlan);
    }
    
    /// Optimize single target (for incremental builds)
    BuildResult!BuildPlan optimizeTarget(BuildNode target, OptimizationConstraints constraints) @trusted
    {
        auto estimateResult = estimator.estimateNode(target);
        if (estimateResult.isErr)
            return Err!(BuildPlan, BuildError)(estimateResult.unwrapErr());
        
        auto estimate = estimateResult.unwrap();
        immutable cacheHitProb = estimator.estimateCacheHitProbabilityForNode(target);
        
        auto candidates = enumerator.enumerate(estimate.duration, estimate.usage, cacheHitProb, pricingConfig.effectivePricing());
        auto pareto = ParetoFrontier.compute(candidates);
        
        BuildPlan selectedPlan;
        final switch (constraints.objective)
        {
            case OptimizationObjective.MinimizeCost: selectedPlan = pareto.optimizeForCost(); break;
            case OptimizationObjective.MinimizeTime: selectedPlan = pareto.optimizeForTime(); break;
            case OptimizationObjective.Balanced: selectedPlan = pareto.optimizeBalanced(); break;
            case OptimizationObjective.Budget: selectedPlan = pareto.findWithinBudget(constraints.budgetUSD); break;
            case OptimizationObjective.TimeLimit: selectedPlan = pareto.findWithinTime(constraints.timeLimit); break;
        }
        
        return Ok!(BuildPlan, BuildError)(selectedPlan);
    }
    
    /// Compare two plans and recommend better one
    string comparePlans(const BuildPlan a, const BuildPlan b, float alpha = 0.5f) const pure @safe
    {
        import std.format : format;
        
        immutable costDiff = b.expectedCost() - a.expectedCost();
        immutable timeDiff = b.expectedTime().total!"seconds" - a.expectedTime().total!"seconds";
        
        if (a.dominates(b)) return "Plan A dominates (better in both cost and time)";
        if (b.dominates(a)) return "Plan B dominates (better in both cost and time)";
        if (costDiff < 0 && timeDiff > 0) return format("Plan A is $%.2f cheaper but %ds slower", -costDiff, timeDiff);
        if (costDiff > 0 && timeDiff < 0) return format("Plan A is $%.2f more expensive but %ds faster", costDiff, -timeDiff);
        return "Plans are non-comparable (Pareto-optimal tradeoff)";
    }
}

/// Economics-specific errors
class EconomicsError : BaseBuildError
{
    this(string message, string file = __FILE__, size_t line = __LINE__) @trusted
    {
        super(Config.Error, message);
        addContext(ErrorContext("file", file));
        addContext(ErrorContext("line", line.to!string));
    }
}

/// Helper: Format duration for display
private string formatDuration(Duration d) pure @safe
{
    immutable totalSeconds = d.total!"seconds";
    if (totalSeconds < 60) return totalSeconds.to!string ~ "s";
    if (totalSeconds < 3600) return (totalSeconds / 60).to!string ~ "m " ~ (totalSeconds % 60).to!string ~ "s";
    return (totalSeconds / 3600).to!string ~ "h " ~ ((totalSeconds % 3600) / 60).to!string ~ "m";
}
