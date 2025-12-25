# Build Provenance

SLSA-compliant build provenance attestations for software supply chain security.

## Overview

Build provenance provides cryptographically signed attestations documenting how software artifacts were built:

- **Verification**: Prove artifacts came from trusted builds
- **Compliance**: Meet supply chain security requirements (EO 14028, SLSA)
- **Auditability**: Track complete build lineage

## SLSA Levels

| Level | Description | bldr Support |
|-------|-------------|--------------|
| L0 | No provenance | — |
| L1 | Provenance exists | ✓ Automatic |
| L2 | Hosted build platform | ✓ CI/CD |
| L3 | Hardened builds | ✓ Hermetic mode |

## Quick Start

```bash
# Verify provenance from a file
bldr verify --provenance build.provenance.json

# Verify with minimum SLSA level requirement
bldr verify --provenance build.provenance.json --slsa-level L2
```

## Output Format

### SLSA Provenance v1.0 (in-toto Statement)

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [
    {
      "name": "bin/myapp",
      "digest": { "blake3": "abc123def456..." }
    }
  ],
  "predicateType": "https://slsa.dev/provenance/v1",
  "predicate": {
    "buildDefinition": {
      "buildType": "https://bldr.dev/buildtypes/build/v1",
      "resolvedDependencies": [
        {
          "uri": "file://src/main.d",
          "digest": { "blake3": "..." }
        }
      ]
    },
    "runDetails": {
      "builder": {
        "id": "https://bldr.dev/builder/v1",
        "version": "0.1.0"
      },
      "metadata": {
        "invocationId": "550e8400-e29b-41d4-a716-446655440000",
        "startedOn": "2024-01-15T10:30:00Z",
        "finishedOn": "2024-01-15T10:30:45Z"
      }
    }
  }
}
```

### Signed Envelope (DSSE)

```json
{
  "payloadType": "application/vnd.in-toto+json",
  "payload": "eyJfdHlwZSI6Imh0dHBzOi8vaW4tdG90by...",
  "signatures": [
    {
      "keyid": "bldr:a1b2c3d4e5f6",
      "sig": "YWJjMTIzZGVmNDU2Li4u",
      "signingAlgorithm": "blake3-hmac"
    }
  ]
}
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `BLDR_PROVENANCE_ENABLED` | Enable provenance generation | `true` |
| `BLDR_PROVENANCE_SIGN` | Sign attestations | `true` |
| `BLDR_SLSA_LEVEL` | Target SLSA level (L1/L2/L3) | `L1` |
| `BLDR_SIGNING_KEY` | Path to signing key | workspace-derived |

### Builderfile Configuration

```
workspace "myproject" {
    provenance {
        enabled: true
        sign: true
        level: L3
        include_byproducts: false
    }
}
```

## Programmatic API

```d
import engine.provenance;

// Create generator
auto gen = ProvenanceGenerator.create();
gen.startBuild(hermetic: true);

// Record materials (inputs)
gen.addMaterial("src/main.d");
gen.addMaterials(["lib/utils.d", "lib/core.d"]);

// Record resolved dependencies
gen.addResolvedDependency(
    "https://github.com/dlang/phobos",
    "abc123...",
    "phobos"
);

// Record outputs
gen.addOutput("bin/myapp", "myapp");

// Build parameters
gen.setParameter("optimization", "-O2");
gen.setParameter("target", "x86_64-linux");

// Finalize
auto result = gen.finalize();
if (result.isOk)
{
    auto prov = result.unwrap();
    
    // Sign
    auto signer = ProvenanceSigner.fromWorkspace(".");
    auto envelope = signer.sign(prov).unwrap();
    
    // Export to file
    ProvenanceExporter.writeToFile(prov, "build.provenance.json");
    
    // Human-readable summary
    writeln(ProvenanceExporter.toSummary(prov));
}
```

## Verification

```d
import engine.provenance;

// Create verifier with requirements
auto verifier = ProvenanceVerifier.create(".", SLSALevel.L2);

// Verify from file
auto result = verifier.verifyFile("build.provenance.json");
if (result.isOk)
{
    auto verification = result.unwrap();
    if (verification.passed())
        writeln("✓ Provenance verified");
    else
    {
        writeln("✗ Verification failed:");
        foreach (v; verification.violations)
            writeln("  - ", v);
    }
}

// Verify outputs match provenance
auto outputsMatch = verifier.verifyOutputs(prov, ["bin/myapp"]);
```

## CI/CD Integration

### GitHub Actions

```yaml
name: Build with Provenance

on: [push]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Build
        run: bldr build
        env:
          BLDR_PROVENANCE_ENABLED: "true"
          BLDR_SLSA_LEVEL: "L2"
      
      - name: Upload provenance
        uses: actions/upload-artifact@v4
        with:
          name: provenance
          path: "*.provenance.json"
```

### GitLab CI

```yaml
build:
  stage: build
  script:
    - bldr build
  variables:
    BLDR_PROVENANCE_ENABLED: "true"
    BLDR_SLSA_LEVEL: "L2"
  artifacts:
    paths:
      - "*.provenance.json"
```

## Security

### Signing Keys

- **Workspace-derived** (default): Key derived from workspace path + machine ID
- **Custom key**: Set `BLDR_SIGNING_KEY` for consistent keys across machines
- **Key rotation**: Re-sign provenance when rotating keys

### Verification Best Practices

1. Verify provenance in deployment pipelines
2. Check SLSA level meets requirements
3. Verify output hashes match subjects
4. Validate builder identity

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Build Execution                          │
│  ┌─────────────────────────────────────────────────────────┐│
│  │ ProvenanceCollector (thread-safe)                       ││
│  │   • recordMaterial(path)                                ││
│  │   • recordOutput(path)                                  ││
│  │   • recordParameter(key, value)                         ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                  ProvenanceGenerator                        │
│   • Materials (inputs with BLAKE3 hashes)                   │
│   • Outputs (subjects with digests)                         │
│   • Build metadata (timestamps, ID)                         │
│   • Builder identity                                        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   ProvenanceSigner                          │
│   • BLAKE3-HMAC signature                                   │
│   • DSSE envelope format                                    │
│   • Workspace-derived or custom key                         │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                 ProvenanceExporter                          │
│   • SLSA v1.0 JSON                                          │
│   • Signed DSSE envelope                                    │
│   • Human-readable summary                                  │
└─────────────────────────────────────────────────────────────┘
```

## Related Features

- [Determinism](determinism.md) — Reproducible builds
- [Hermetic](hermetic.md) — Isolated build environments
- [Verification](verification.md) — Build correctness proofs
- [Remote Execution](remote-execution.md) — Distributed builds with provenance
