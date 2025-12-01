module engine.economics;

/// Economic Optimization for Build Systems
/// 
/// 
/// ## Problem
/// 
/// Traditional build systems optimize for a single objective: minimize build time.
/// However, builds consume resources (CPU, memory, network) which have real economic cost,
/// especially in CI/CD at scale.
/// 
/// ## Solution
/// 
/// Multi-objective optimization that computes **Pareto-optimal** solutions
/// across the time-cost tradeoff space.
/// 
/// ## Core Concepts
/// 
/// ### 1. Resource Pricing
/// Model actual cloud costs:
/// - CPU-hours (per core)
/// - Memory-GB-hours
/// - Network transfer (GB)
/// - Storage I/O operations
/// 
/// ### 2. Execution Strategies
/// Different ways to execute a build:
/// - **Local**: $0 cost, slower (uses developer machine)
/// - **Cached**: ~$0 cost, very fast (cache hit)
/// - **Distributed**: Variable cost, fast (remote workers)
/// - **Premium**: High cost, fastest (dedicated instances)
/// 
/// ### 3. Build Plans
/// A build plan specifies:
/// - Which strategy to use for each target
/// - Resource allocation (cores, memory, workers)
/// - Expected time and cost
/// 
/// ### 4. Optimization Modes
/// - `--budget=$X`: Find fastest build within budget
/// - `--time-limit=Xm`: Find cheapest build within time limit
/// - `--optimize=cost`: Minimize cost (no time constraint)
/// - `--optimize=time`: Minimize time (no cost constraint)
/// - `--optimize=balanced`: Pareto-optimal balance
/// 
/// ## Architecture
/// 
/// ```
/// ┌─────────────────────────────────────────────────────┐
/// │                  Build Coordinator                   │
/// │                                                      │
/// │  ┌────────────────────────────────────────────┐    │
/// │  │         Cost Optimizer                     │    │
/// │  │                                            │    │
/// │  │  1. Estimate cost/time for each strategy  │    │
/// │  │  2. Compute Pareto frontier               │    │
/// │  │  3. Select optimal plan                    │    │
/// │  │  4. Apply constraints (budget/time)       │    │
/// │  └────────────────────────────────────────────┘    │
/// │                       │                             │
/// │                       ▼                             │
/// │  ┌─────────────────────────────────────────────┐   │
/// │  │           Build Plan                        │   │
/// │  │  { strategy: Distributed, workers: 16,     │   │
/// │  │    cost: $4.87, time: 5m 20s }             │   │
/// │  └─────────────────────────────────────────────┘   │
/// │                       │                             │
/// └───────────────────────┼─────────────────────────────┘
///                         │
///                         ▼
///                  Execute Build
/// ```
/// 
/// ## Usage
/// 
/// ### Optimize for budget
/// ```bash
/// $ bldr build --budget=$5.00
/// Using: 4 remote cores, shared cache
/// Est cost: $4.87, Est time: 5m 20s
/// ```
/// 
/// ### Optimize for time
/// ```bash
/// $ bldr build --time-limit=2m
/// Using: 32 remote cores, premium instances  
/// Est cost: $12.30, Est time: 1m 55s
/// ```
/// 
/// ### Optimize for cost
/// ```bash
/// $ bldr build --optimize=cost
/// Found: Local build with distributed cache
/// Cost: $0.00, Time: 8m 15s
/// ```
/// 
/// ## Implementation Strategy
/// 
/// ### Phase 1: Pricing Model
/// - Define `ResourcePricing` struct with $/unit rates
/// - Load from config or environment
/// - Support multiple pricing tiers (spot, on-demand, premium)
/// 
/// ### Phase 2: Cost Estimator
/// - Historical execution data → time estimates
/// - Resource usage tracking → cost estimates
/// - Cache hit probability → expected savings
/// 
/// ### Phase 3: Optimizer
/// - Enumerate execution strategies
/// - Estimate cost/time for each
/// - Compute Pareto frontier
/// - Select plan based on constraints
/// 
/// ### Phase 4: Integration
/// - Wire into BuildCoordinator
/// - Add CLI flags
/// - Display cost/time estimates
/// - Track actual vs estimated
/// 
/// ## Mathematical Foundation
/// 
/// ### Pareto Optimality
/// 
/// A build plan P is Pareto-optimal if there is no other plan P' such that:
/// - cost(P') ≤ cost(P) AND time(P') ≤ time(P)
/// - with at least one strict inequality
/// 
/// ### Optimization Problem
/// 
/// ```
/// minimize    α·cost(P) + (1-α)·time(P)
/// subject to  cost(P) ≤ budget         (if budget specified)
///             time(P) ≤ timeLimit       (if time limit specified)
///             P ∈ feasible_plans
/// 
/// where α ∈ [0,1] is the cost-time tradeoff parameter
/// ```
/// 
/// ### Execution Strategy Selection
/// 
/// For each target t:
/// ```
/// cost(t, strategy) = cpuCost(t) + memoryCost(t) + networkCost(t)
/// time(t, strategy) = computeTime(t) + transferTime(t) + overhead(t)
/// 
/// cpuCost(t) = cores(t) × duration(t) × pricePerCoreHour
/// memoryCost(t) = memory(t) × duration(t) × pricePerGBHour
/// networkCost(t) = transferSize(t) × pricePerGB
/// ```
/// 
/// ### Cache Value
/// 
/// Cache hits have enormous value:
/// ```
/// expectedCost(t) = P(hit) × cacheCost + P(miss) × computeCost
///                 = P(hit) × ε + P(miss) × C
/// 
/// where ε ≈ 0 (cache lookup is cheap)
/// ```
/// 
/// ## See Also
/// 
/// - `pricing.d` - Resource pricing models
/// - `optimizer.d` - Pareto-optimal plan selection
/// - `estimator.d` - Cost/time estimation
/// - `strategies.d` - Execution strategy enumeration
/// - `tracking.d` - Historical cost tracking

public import engine.economics.pricing;
public import engine.economics.optimizer;
public import engine.economics.estimator;
public import engine.economics.strategies;
public import engine.economics.tracking;
public import engine.economics.integration;