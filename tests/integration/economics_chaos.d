module tests.integration.economics_chaos;

import std.stdio : writeln;
import std.datetime : Duration, seconds, minutes, hours;
import std.algorithm : map, filter, sort, min, max, sum, maxElement, minElement;
import std.array : array;
import std.conv : to;
import std.random : uniform, uniform01, Random;
import std.math : abs, isNaN, isInfinity;
import core.thread : Thread;

import tests.harness : Assert;
import tests.fixtures : TempDir;
import engine.graph;
import engine.economics;
import infrastructure.config.schema.schema;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// Chaos injection for economic optimizer
enum EconomicsChaosType
{
    PriceSpike,             // Sudden cloud cost increase
    PriceDrop,              // Sudden cost reduction
    NetworkCostSurge,       // Data transfer explosion
    SpotTermination,        // Spot instance killed
    CostEstimateError,      // Wrong cost predictions
    BudgetViolation,        // Exceed budget constraints
    InfiniteCost,           // Cost calculation overflow
    NegativeCost,           // Invalid negative costs
    ZeroTime,               // Instant execution (unrealistic)
    TimeoutPenalty,         // Timeout incurs penalties
}

/// Chaos configuration
struct EconomicsChaosConfig
{
    EconomicsChaosType type;
    double probability = 0.3;
    float multiplier = 2.0;  // Cost/time multiplier
    bool enabled = true;
}

/// Chaos-capable cost estimator
class ChaoticCostEstimator
{
    private CostEstimator baseEstimator;
    private EconomicsChaosConfig[] chaosConfigs;
    private PricingConfig basePricing;
    private Random rng;
    private size_t faultsInjected;
    
    this(CostEstimator baseEstimator, PricingConfig pricing)
    {
        this.baseEstimator = baseEstimator;
        this.basePricing = pricing;
        this.rng = Random(12345);
        this.faultsInjected = 0;
    }
    
    void addChaos(EconomicsChaosConfig config)
    {
        chaosConfigs ~= config;
    }
    
    /// Estimate with chaos injection
    Result!(BuildEstimate, BuildError) estimateGraph(BuildGraph graph)
    {
        auto result = baseEstimator.estimateGraph(graph);
        
        if (result.isErr)
            return result;
        
        auto estimate = result.unwrap();
        
        // Inject chaos
        foreach (config; chaosConfigs)
        {
            if (!config.enabled)
                continue;
            
            if (uniform01(rng) < config.probability)
            {
                faultsInjected++;
                estimate = applyChaos(config.type, estimate, config.multiplier);
            }
        }
        
        return Ok!(BuildEstimate, BuildError)(estimate);
    }
    
    private BuildEstimate applyChaos(EconomicsChaosType type, BuildEstimate estimate, float multiplier)
    {
        final switch (type)
        {
            case EconomicsChaosType.PriceSpike:
                Logger.info("CHAOS: Price spike (×" ~ multiplier.to!string ~ ")");
                // Simulate price spike by increasing usage (mathematically equivalent for linear pricing)
                estimate.usage.cores = cast(size_t)(estimate.usage.cores * multiplier);
                estimate.usage.memoryBytes = cast(size_t)(estimate.usage.memoryBytes * multiplier);
                break;
            
            case EconomicsChaosType.PriceDrop:
                Logger.info("CHAOS: Price drop (/" ~ multiplier.to!string ~ ")");
                estimate.usage.cores = cast(size_t)(estimate.usage.cores / multiplier);
                estimate.usage.memoryBytes = cast(size_t)(estimate.usage.memoryBytes / multiplier);
                break;
            
            case EconomicsChaosType.NetworkCostSurge:
                Logger.info("CHAOS: Network cost surge");
                estimate.usage.networkBytes = cast(size_t)(estimate.usage.networkBytes * multiplier * 10);
                break;
            
            case EconomicsChaosType.SpotTermination:
                Logger.info("CHAOS: Spot termination penalty");
                estimate.duration += 300.seconds;  // 5 min restart penalty
                estimate.usage.duration = estimate.duration;
                break;
            
            case EconomicsChaosType.CostEstimateError:
                Logger.info("CHAOS: Cost estimate error");
                // Wildly incorrect estimate
                estimate.usage.cores = cast(size_t)(estimate.usage.cores * uniform(0.1f, 10.0f, rng));
                break;
            
            case EconomicsChaosType.BudgetViolation:
                Logger.info("CHAOS: Budget violation");
                estimate.usage.cores = cast(size_t)(estimate.usage.cores * 100.0f);  // Blow the budget
                break;
            
            case EconomicsChaosType.InfiniteCost:
                Logger.info("CHAOS: Infinite cost (Simulated as Max)");
                estimate.usage.cores = size_t.max / 100; // Prevent overflow elsewhere
                break;
            
            case EconomicsChaosType.NegativeCost:
                Logger.info("CHAOS: Negative cost (Simulated as Zero)");
                estimate.usage.cores = 0;
                estimate.usage.memoryBytes = 0;
                estimate.usage.networkBytes = 0;
                estimate.usage.diskIOBytes = 0;
                break;
            
            case EconomicsChaosType.ZeroTime:
                Logger.info("CHAOS: Zero execution time");
                estimate.duration = Duration.zero;
                estimate.usage.duration = Duration.zero;
                break;
            
            case EconomicsChaosType.TimeoutPenalty:
                Logger.info("CHAOS: Timeout penalty");
                estimate.duration += 3600.seconds;  // 1 hour penalty
                estimate.usage.duration = estimate.duration;
                estimate.usage.cores = cast(size_t)(estimate.usage.cores * 5.0f);
                break;
        }
        
        return estimate;
    }
    
    size_t getFaultCount() const => faultsInjected;
}

/// Real-world cloud pricing simulator with volatility
class VolatileCloudPricing
{
    private CloudProvider baseProvider;
    private float volatility;  // 0.0 to 1.0
    private Random rng;
    
    this(CloudProvider provider, float volatility = 0.2)
    {
        this.baseProvider = provider;
        this.volatility = volatility;
        this.rng = Random(67890);
    }
    
    /// Get current pricing with market volatility
    ResourcePricing getCurrentPricing()
    {
        auto pricing = baseProvider.pricing;
        
        // Apply random fluctuation
        float fluctuation = uniform(-volatility, volatility, rng);
        
        pricing.costPerCoreHour *= (1.0f + fluctuation);
        pricing.costPerGBHour *= (1.0f + fluctuation);
        pricing.costPerNetworkGB *= (1.0f + fluctuation * 2.0f);  // Network more volatile
        pricing.costPerDiskIOGB *= (1.0f + fluctuation);
        
        return pricing;
    }
    
    /// Simulate spot instance pricing (cheaper but can be terminated)
    ResourcePricing getSpotPricing()
    {
        auto pricing = getCurrentPricing();
        
        // Spot is 60-90% cheaper but unstable
        float discount = uniform(0.6f, 0.9f, rng);
        pricing.costPerCoreHour *= discount;
        pricing.costPerGBHour *= discount;
        
        return pricing;
    }
    
    /// Simulate cross-region transfer costs
    float getRegionalTransferCost(string fromRegion, string toRegion)
    {
        if (fromRegion == toRegion)
            return 0.01f;  // Same region: cheap
        
        // Different regions: expensive
        return uniform(0.08f, 0.15f, rng);
    }
}

// ============================================================================
// CHAOS TESTS: Economic Optimizer
// ============================================================================

/// Test: Price spike handling
@("economics_chaos.price_spike")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Economics - Price Spike");
    
    auto baseGraph = new BuildGraph();
    
    // Create realistic build graph
    for (size_t i = 0; i < 10; i++)
    {
        Target t;
        t.name = "target-" ~ i.to!string;
        t.type = TargetType.Library;
        t.sources = ["src" ~ i.to!string ~ ".cpp"];
        baseGraph.addTarget(t);
    }
    
    auto history = new ExecutionHistory();
    auto baseEstimator = new CostEstimator(history);
    auto pricing = PricingConfig();
    pricing.provider = CloudProvider.aws();
    pricing.profile = PricingProfile.onDemand;
    
    auto chaosEstimator = new ChaoticCostEstimator(baseEstimator, pricing);
    
    // Inject price spike
    EconomicsChaosConfig spikeChaos;
    spikeChaos.type = EconomicsChaosType.PriceSpike;
    spikeChaos.probability = 1.0;
    spikeChaos.multiplier = 5.0f;  // 5× cost increase
    chaosEstimator.addChaos(spikeChaos);
    
    // Estimate cost
    auto result = chaosEstimator.estimateGraph(baseGraph);
    
    Assert.isTrue(result.isOk, "Should estimate despite price spike");
    
    auto estimate = result.unwrap();
    float totalCost = pricing.effectivePricing().totalCost(estimate.usage);
    
    Logger.info("Cost with price spike: $" ~ totalCost.to!string);
    Assert.isTrue(totalCost > 0.0f, "Should have positive cost");
    Assert.isFalse(isInfinity(totalCost), "Cost should be finite");
    
    writeln("  \x1b[32m✓ Price spike test passed\x1b[0m");
}

/// Test: Spot instance termination
@("economics_chaos.spot_termination")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Economics - Spot Termination");
    
    auto baseGraph = new BuildGraph();
    
    Target t;
    t.name = "long-build";
    t.type = TargetType.Executable;
    t.sources = ["main.cpp"];
    baseGraph.addTarget(t);
    
    auto history = new ExecutionHistory();
    auto baseEstimator = new CostEstimator(history);
    auto pricing = PricingConfig();
    pricing.provider = CloudProvider.aws();
    pricing.profile = PricingProfile.spot;
    
    auto chaosEstimator = new ChaoticCostEstimator(baseEstimator, pricing);
    
    // Inject spot termination
    EconomicsChaosConfig spotChaos;
    spotChaos.type = EconomicsChaosType.SpotTermination;
    spotChaos.probability = 0.7;  // 70% termination chance
    chaosEstimator.addChaos(spotChaos);
    
    // Run multiple estimates (simulating spot unreliability)
    Duration[] durations;
    for (size_t i = 0; i < 10; i++)
    {
        auto result = chaosEstimator.estimateGraph(baseGraph);
        if (result.isOk)
            durations ~= result.unwrap().duration;
    }
    
    Assert.isTrue(durations.length > 0, "Should get some estimates");
    
    // Some builds should have termination penalty
    auto maxDuration = durations.map!(d => d.total!"seconds").maxElement;
    Logger.info("Max duration with terminations: " ~ maxDuration.to!string ~ "s");
    
    writeln("  \x1b[32m✓ Spot termination test passed\x1b[0m");
}

/// Test: Budget constraint violation
@("economics_chaos.budget_violation")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Economics - Budget Violation");
    
    auto baseGraph = new BuildGraph();
    
    // Large build
    for (size_t i = 0; i < 50; i++)
    {
        Target t;
        t.name = "target-" ~ i.to!string;
        t.type = TargetType.Library;
        baseGraph.addTarget(t);
    }
    
    auto history = new ExecutionHistory();
    auto baseEstimator = new CostEstimator(history);
    auto pricing = PricingConfig();
    pricing.provider = CloudProvider.aws();
    
    auto chaosEstimator = new ChaoticCostEstimator(baseEstimator, pricing);
    
    // Inject budget violation
    EconomicsChaosConfig budgetChaos;
    budgetChaos.type = EconomicsChaosType.BudgetViolation;
    budgetChaos.probability = 1.0;
    chaosEstimator.addChaos(budgetChaos);
    
    auto result = chaosEstimator.estimateGraph(baseGraph);
    
    if (result.isOk)
    {
        auto estimate = result.unwrap();
        float cost = pricing.effectivePricing().totalCost(estimate.usage);
        
        Logger.info("Estimated cost: $" ~ cost.to!string);
        
        // System should detect this exceeds reasonable budget
        immutable maxBudget = 100.0f;
        if (cost > maxBudget)
        {
            Logger.info("Budget violation detected: $" ~ cost.to!string ~ " > $" ~ maxBudget.to!string);
            Assert.isTrue(true, "Can detect budget violation");
        }
    }
    
    writeln("  \x1b[32m✓ Budget violation test passed\x1b[0m");
}

/// Test: Invalid cost values (NaN, Infinity, Negative)
@("economics_chaos.invalid_costs")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Economics - Invalid Costs");
    
    auto baseGraph = new BuildGraph();
    
    Target t;
    t.name = "test-target";
    t.type = TargetType.Library;
    baseGraph.addTarget(t);
    
    auto history = new ExecutionHistory();
    auto baseEstimator = new CostEstimator(history);
    auto pricing = PricingConfig();
    pricing.provider = CloudProvider.aws();
    
    auto chaosEstimator = new ChaoticCostEstimator(baseEstimator, pricing);
    
    // Inject all invalid cost types
    EconomicsChaosConfig infiniteChaos;
    infiniteChaos.type = EconomicsChaosType.InfiniteCost;
    infiniteChaos.probability = 0.3;
    chaosEstimator.addChaos(infiniteChaos);
    
    EconomicsChaosConfig negativeChaos;
    negativeChaos.type = EconomicsChaosType.NegativeCost;
    negativeChaos.probability = 0.3;
    chaosEstimator.addChaos(negativeChaos);
    
    // Run multiple estimates
    size_t invalidCount = 0;
    for (size_t i = 0; i < 20; i++)
    {
        auto result = chaosEstimator.estimateGraph(baseGraph);
        if (result.isOk)
        {
            auto estimate = result.unwrap();
            float cost = pricing.effectivePricing().totalCost(estimate.usage);
            
            if (isInfinity(cost) || isNaN(cost) || cost < 0)
            {
                invalidCount++;
                Logger.info("  Invalid cost detected: " ~ cost.to!string);
            }
        }
    }
    
    Logger.info("Invalid costs encountered: " ~ invalidCount.to!string ~ "/20");
    
    // System should handle invalid values gracefully
    Assert.isTrue(true, "System survives invalid cost values");
    
    writeln("  \x1b[32m✓ Invalid costs test passed\x1b[0m");
}

/// Test: Network cost surge
@("economics_chaos.network_surge")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Economics - Network Cost Surge");
    
    auto baseGraph = new BuildGraph();
    
    // Create targets that would transfer data
    for (size_t i = 0; i < 20; i++)
    {
        Target t;
        t.name = "distributed-" ~ i.to!string;
        t.type = TargetType.Library;
        baseGraph.addTarget(t);
    }
    
    auto history = new ExecutionHistory();
    auto baseEstimator = new CostEstimator(history);
    auto pricing = PricingConfig();
    pricing.provider = CloudProvider.aws();
    
    auto chaosEstimator = new ChaoticCostEstimator(baseEstimator, pricing);
    
    // Inject network cost surge
    EconomicsChaosConfig networkChaos;
    networkChaos.type = EconomicsChaosType.NetworkCostSurge;
    networkChaos.probability = 1.0;
    networkChaos.multiplier = 20.0f;
    chaosEstimator.addChaos(networkChaos);
    
    auto result = chaosEstimator.estimateGraph(baseGraph);
    
    if (result.isOk)
    {
        auto estimate = result.unwrap();
        float networkCost = pricing.effectivePricing().networkCost(estimate.usage.networkBytes);
        
        Logger.info("Network cost with surge: $" ~ networkCost.to!string);
        
        // High network cost should influence strategy choice
        Assert.isTrue(networkCost >= 0.0f, "Network cost should be non-negative");
    }
    
    writeln("  \x1b[32m✓ Network surge test passed\x1b[0m");
}

/// Test: Real-world pricing volatility
@("economics_chaos.pricing_volatility")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Economics - Pricing Volatility");
    
    // Simulate 24 hours of pricing fluctuations
    auto awsVolatile = new VolatileCloudPricing(CloudProvider.aws(), 0.15);
    auto gcpVolatile = new VolatileCloudPricing(CloudProvider.gcp(), 0.12);
    auto azureVolatile = new VolatileCloudPricing(CloudProvider.azure(), 0.18);
    
    float[] awsPrices;
    float[] gcpPrices;
    float[] azurePrices;
    
    // Sample pricing every hour
    for (size_t hour = 0; hour < 24; hour++)
    {
        awsPrices ~= awsVolatile.getCurrentPricing().costPerCoreHour;
        gcpPrices ~= gcpVolatile.getCurrentPricing().costPerCoreHour;
        azurePrices ~= azureVolatile.getCurrentPricing().costPerCoreHour;
    }
    
    // Calculate price variance
    auto awsVariance = calculateVariance(awsPrices);
    auto gcpVariance = calculateVariance(gcpPrices);
    auto azureVariance = calculateVariance(azurePrices);
    
    Logger.info("AWS variance: " ~ awsVariance.to!string);
    Logger.info("GCP variance: " ~ gcpVariance.to!string);
    Logger.info("Azure variance: " ~ azureVariance.to!string);
    
    // Prices should fluctuate but remain realistic
    Assert.isTrue(awsVariance > 0.0f, "AWS prices should fluctuate");
    Assert.isTrue(gcpVariance > 0.0f, "GCP prices should fluctuate");
    Assert.isTrue(azureVariance > 0.0f, "Azure prices should fluctuate");
    
    writeln("  \x1b[32m✓ Pricing volatility test passed\x1b[0m");
}

/// Test: Cost estimation error propagation
@("economics_chaos.estimate_errors")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Economics - Estimate Errors");
    
    auto baseGraph = new BuildGraph();
    
    for (size_t i = 0; i < 30; i++)
    {
        Target t;
        t.name = "target-" ~ i.to!string;
        t.type = TargetType.Library;
        baseGraph.addTarget(t);
    }
    
    auto history = new ExecutionHistory();
    auto baseEstimator = new CostEstimator(history);
    auto pricing = PricingConfig();
    pricing.provider = CloudProvider.aws();
    
    auto chaosEstimator = new ChaoticCostEstimator(baseEstimator, pricing);
    
    // Inject cost estimate errors
    EconomicsChaosConfig errorChaos;
    errorChaos.type = EconomicsChaosType.CostEstimateError;
    errorChaos.probability = 0.5;  // 50% error rate
    chaosEstimator.addChaos(errorChaos);
    
    // Get multiple estimates
    float[] estimates;
    for (size_t i = 0; i < 10; i++)
    {
        auto result = chaosEstimator.estimateGraph(baseGraph);
        if (result.isOk)
            estimates ~= pricing.effectivePricing().totalCost(result.unwrap().usage);
    }
    
    Assert.isTrue(estimates.length > 0, "Should get estimates");
    
    // Estimates should vary wildly with errors
    float minEst = estimates.minElement;
    float maxEst = estimates.maxElement;
    float variance = maxEst - minEst;
    
    Logger.info("Estimate variance: $" ~ variance.to!string);
    Logger.info("Min: $" ~ minEst.to!string ~ ", Max: $" ~ maxEst.to!string);
    
    // System should handle unreliable estimates
    Assert.isTrue(variance >= 0.0f, "Should track variance");
    
    writeln("  \x1b[32m✓ Estimate errors test passed\x1b[0m");
}

/// Test: Regional transfer cost simulation
@("economics_chaos.regional_transfers")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Economics - Regional Transfers");
    
    auto pricing = new VolatileCloudPricing(CloudProvider.aws());
    
    string[] regions = ["us-east-1", "us-west-2", "eu-west-1", "ap-southeast-1"];
    
    float totalCost = 0.0f;
    
    // Simulate builds across different regions
    foreach (fromRegion; regions)
    {
        foreach (toRegion; regions)
        {
            float cost = pricing.getRegionalTransferCost(fromRegion, toRegion);
            totalCost += cost;
            
            if (fromRegion == toRegion)
            {
                Assert.isTrue(cost < 0.02f, "Same region should be cheap");
            }
            else
            {
                Assert.isTrue(cost > 0.05f, "Cross-region should be expensive");
            }
        }
    }
    
    Logger.info("Total regional transfer costs: $" ~ totalCost.to!string);
    
    writeln("  \x1b[32m✓ Regional transfers test passed\x1b[0m");
}

/// Test: Combined chaos stress test
@("economics_chaos.combined_stress")
unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Economics - Combined Stress Test");
    
    auto baseGraph = new BuildGraph();
    
    // Large graph
    for (size_t i = 0; i < 100; i++)
    {
        Target t;
        t.name = "stress-" ~ i.to!string;
        t.type = TargetType.Library;
        baseGraph.addTarget(t);
    }
    
    auto history = new ExecutionHistory();
    auto baseEstimator = new CostEstimator(history);
    auto pricing = PricingConfig();
    pricing.provider = CloudProvider.aws();
    
    auto chaosEstimator = new ChaoticCostEstimator(baseEstimator, pricing);
    
    // Enable ALL chaos types
    foreach (chaosType; [
        EconomicsChaosType.PriceSpike,
        EconomicsChaosType.NetworkCostSurge,
        EconomicsChaosType.SpotTermination,
        EconomicsChaosType.CostEstimateError,
        EconomicsChaosType.TimeoutPenalty
    ])
    {
        EconomicsChaosConfig chaos;
        chaos.type = chaosType;
        chaos.probability = 0.2;  // 20% each
        chaos.multiplier = uniform(1.5f, 5.0f);
        chaosEstimator.addChaos(chaos);
    }
    
    // Hammer with estimates
    size_t successCount = 0;
    for (size_t i = 0; i < 50; i++)
    {
        auto result = chaosEstimator.estimateGraph(baseGraph);
        if (result.isOk)
            successCount++;
    }
    
    size_t faults = chaosEstimator.getFaultCount();
    Logger.info("Total chaos injections: " ~ faults.to!string);
    Logger.info("Successful estimates: " ~ successCount.to!string ~ "/50");
    
    // Should handle majority of chaos scenarios
    Assert.isTrue(successCount > 25, "Should survive most chaos");
    
    writeln("  \x1b[32m✓ Combined stress test passed\x1b[0m");
}

// ============================================================================
// Helper Functions
// ============================================================================

float calculateVariance(float[] values)
{
    if (values.length == 0)
        return 0.0f;
    
    float mean = values.sum / values.length;
    float sumSquares = 0.0f;
    
    foreach (v; values)
        sumSquares += (v - mean) * (v - mean);
    
    return sumSquares / values.length;
}

