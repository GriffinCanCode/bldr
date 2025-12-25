# Build Verification Architecture

**Status:** Implemented  
**Version:** 1.0

---

## Overview

Builder provides formal verification of build graph properties:

| Property | Description | Method |
|----------|-------------|--------|
| **Acyclicity** | Graph is a DAG | Constructive proof via topological ordering |
| **Hermeticity** | Inputs and outputs disjoint (I ∩ O = ∅) | Set-theoretic verification |
| **Determinism** | Same inputs → same outputs | Content-addressable hashing (BLAKE3) |
| **Race-freedom** | No data races in parallel execution | Happens-before analysis |

---

## Architecture

```
source/engine/graph/verification/
├── proof.d      # All proof types and BuildVerifier
└── package.d    # Public API
```

---

## Proof Types

### BuildProof

```d
struct BuildProof {
    AcyclicityProof acyclicity;
    HermeticityProof hermeticity;
    DeterminismProof determinism;
    RaceFreedomProof raceFreedom;
    SysTime timestamp;
    string proofHash;  // BLAKE3 hash for integrity
    
    bool isValid() const @safe pure nothrow {
        return acyclicity.isValid && hermeticity.isValid &&
               determinism.isValid && raceFreedom.isValid;
    }
}
```

### AcyclicityProof

```d
struct AcyclicityProof {
    string[] topoOrder;    // Topological ordering (constructive proof)
    bool uniqueness;       // Each node appears once
    bool forwardEdges;     // All edges point forward in ordering
    SysTime timestamp;
    
    bool isValid() const => uniqueness && forwardEdges && topoOrder.length > 0;
}
```

### HermeticityProof

```d
struct HermeticityProof {
    PathSet inputs;           // I = all source paths
    PathSet outputs;          // O = all output paths
    bool disjoint;            // I ∩ O = ∅
    bool isolated;            // Network access N = ∅
    string[] hermeticTargets; // Targets with verified specs
    SysTime timestamp;
    
    bool isValid() const => disjoint && isolated;
}
```

### DeterminismProof

```d
struct DeterminismProof {
    DeterministicSpec[string] specs;  // target → spec
    bool complete;                     // All targets have specs
    SysTime timestamp;
    
    bool isValid() const => complete && specs.length > 0;
}

struct DeterministicSpec {
    string inputsHash;   // BLAKE3 hash of inputs
    string outputsHash;  // Expected outputs hash
    string commandHash;  // Command hash
    string envHash;      // Environment hash
}
```

### RaceFreedomProof

```d
struct RaceFreedomProof {
    HappensBefore[] happensBefore;  // Ordering relations
    bool properlyOrdered;           // All access ordered
    bool atomicAccess;              // Shared state uses atomics
    bool disjointWrites;            // No overlapping writes
    SysTime timestamp;
    
    bool isValid() const => properlyOrdered && atomicAccess && disjointWrites;
}

struct HappensBefore {
    string from;
    string to;
    HBReason reason;  // Dependency, Synchronization, ThreadJoin
}
```

---

## BuildVerifier

```d
struct BuildVerifier {
    static BuildResult!BuildProof verify(BuildGraph graph) @system;
}
```

The verifier:

1. **Acyclicity**: Computes topological sort; if cycle detected, returns error
2. **Hermeticity**: Collects all inputs/outputs; verifies disjoint sets
3. **Determinism**: Generates BLAKE3 hashes for each target's inputs/commands
4. **Race-freedom**: Builds happens-before from dependencies; verifies disjoint writes

---

## Usage

### Generate Proof

```d
import engine.graph.verification;

auto result = BuildVerifier.verify(graph);
if (result.isOk) {
    auto proof = result.unwrap();
    writeln("Acyclicity: ", proof.acyclicity.isValid);
    writeln("Hermeticity: ", proof.hermeticity.isValid);
    writeln("Determinism: ", proof.determinism.isValid);
    writeln("Race-freedom: ", proof.raceFreedom.isValid);
}
```

### Generate Certificate

```d
auto certResult = generateCertificate(graph, "my-workspace");
if (certResult.isOk) {
    auto cert = certResult.unwrap();
    writeln(cert.toString());
    
    // Verify certificate
    auto verifyResult = cert.verify();
    assert(verifyResult.isOk);
}
```

### Certificate Output

```
Build Correctness Certificate
==============================
Workspace: my-workspace
Timestamp: 2024-01-15T10:30:00Z
Proof Hash: a1b2c3d4e5f6...

✓ Acyclicity: 15 (DAG verified)
✓ Hermeticity: 15 (I ∩ O = ∅)
✓ Determinism: 15 specs verified
✓ Race-Freedom: 20 dependencies ordered

Status: VALID
```

---

## Proof Methods

### Acyclicity

**Algorithm:**
1. Compute topological sort via DFS
2. Verify each node appears exactly once
3. Verify all edges point forward in ordering

**Complexity:** O(V+E)

**Proof validity:** Existence of topological ordering implies DAG.

### Hermeticity

**Algorithm:**
1. Collect all source paths into set I
2. Collect all output paths into set O
3. Verify I ∩ O = ∅

**Complexity:** O(|I| + |O|)

### Determinism

**Algorithm:**
1. For each target, compute BLAKE3 hash of:
   - Source files
   - Dependency IDs
   - Build command
   - Environment
2. Store as `DeterministicSpec`

**Property:** Same hash → same inputs → same outputs.

### Race-Freedom

**Algorithm:**
1. Build happens-before relation from dependency edges
2. Verify all write sets are pairwise disjoint
3. Verify shared state uses atomic operations (static check)

**Complexity:** O(V+E) for happens-before, O(V²) for write-set check

---

## ProofCertificate

```d
struct ProofCertificate {
    BuildProof proof;
    string signature;   // BLAKE3-HMAC
    string workspace;
    
    Result!(bool, string) verify() const @system {
        auto expectedHash = BuildVerifier.computeProofHash(proof);
        if (expectedHash != proof.proofHash)
            return Err("Proof hash mismatch");
        if (!proof.isValid())
            return Err("Proof is invalid");
        return Ok(true);
    }
}
```

---

## Performance

| Proof | Complexity |
|-------|------------|
| Acyclicity | O(V+E) |
| Hermeticity | O(V × P) |
| Determinism | O(V × I) |
| Race-freedom | O(V+E) to O(V²) |

Where V = nodes, E = edges, P = paths per target, I = inputs per target.

**Typical verification time:**
- 100 targets: ~40ms
- 1000 targets: ~300ms

---

## Integration

### With Caching

```d
auto spec = proof.determinism.specs[targetId];
auto cacheKey = spec.inputsHash ~ spec.commandHash ~ spec.envHash;
// Same key = safe to use cached result
```

### With Distributed Builds

```d
if (proof.raceFreedom.disjointWrites) {
    // Safe to distribute work across workers
    scheduler.distributeParallel(targets);
}
```

---

## Related Documentation

- [Proof Implementation](../../source/engine/graph/verification/proof.d)
- [Build Graph](../../source/engine/graph/core/graph.d)
- [Hermetic Execution](hermetic.md)
