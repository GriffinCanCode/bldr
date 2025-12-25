# Build Provenance

SLSA-compliant build provenance for software supply chain security.

## Overview

Build provenance provides cryptographically signed attestations of how software artifacts were built. This enables:

- **Verification**: Prove artifacts came from trusted builds
- **Compliance**: Meet enterprise supply chain security requirements
- **Auditability**: Track complete build lineage

## SLSA Levels

| Level | Description | bldr Support |
|-------|-------------|--------------|
| L1 | Provenance exists | ✓ Automatic |
| L2 | Hosted build platform | ✓ CI/CD |
| L3 | Hardened builds | ✓ Hermetic mode |

## Quick Start

```d
import engine.provenance;

// Generate provenance during build
auto gen = ProvenanceGenerator.create();
gen.startBuild(hermetic: true);

// Record materials (inputs)
gen.addMaterial("src/main.d");
gen.addMaterial("lib/utils.d");

// Record outputs
gen.addOutput("bin/app", "myapp");

// Finalize
auto prov = gen.finalize().unwrap();

// Sign and export
auto signer = ProvenanceSigner.fromWorkspace(".");
ProvenanceExporter.writeToFile(prov, "build.provenance.json");
```

## Output Format

### SLSA Provenance v1.0

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "subject": [
    {
      "name": "bin/app",
      "digest": { "blake3": "abc123..." }
    }
  ],
  "predicateType": "https://slsa.dev/provenance/v1",
  "predicate": {
    "buildDefinition": {
      "buildType": "https://bldr.dev/buildtypes/build/v1",
      "resolvedDependencies": [...]
    },
    "runDetails": {
      "builder": { "id": "https://bldr.dev/builder/v1" },
      "metadata": {
        "invocationId": "uuid",
        "startedOn": "2024-01-15T...",
        "finishedOn": "2024-01-15T..."
      }
    }
  }
}
```

### DSSE Envelope (Signed)

```json
{
  "payloadType": "application/vnd.in-toto+json",
  "payload": "base64...",
  "signatures": [
    {
      "keyid": "bldr:abc123",
      "sig": "base64...",
      "signingAlgorithm": "blake3-hmac"
    }
  ]
}
```

## Verification

```d
auto verifier = ProvenanceVerifier.create(".", SLSALevel.L2);
auto result = verifier.verifyFile("build.provenance.json");

if (result.isOk && result.unwrap().passed())
    writeln("✓ Provenance verified");
else
    writeln("✗ Verification failed: ", result.unwrap().violations);
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `BLDR_PROVENANCE_ENABLED` | Enable provenance | `true` |
| `BLDR_PROVENANCE_SIGN` | Sign attestations | `true` |
| `BLDR_SLSA_LEVEL` | Target SLSA level | `L1` |
| `BLDR_SIGNING_KEY` | Path to signing key | workspace-derived |

### Builderfile

```
workspace "myproject" {
    provenance {
        enabled: true
        sign: true
        level: L3
    }
}
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Provenance Module                         │
├─────────────────────────────────────────────────────────────┤
│  types.d      │ SLSA v1.0 types (Statement, Predicate, etc) │
│  generator.d  │ Provenance collection during builds          │
│  signer.d     │ BLAKE3-HMAC signing (DSSE format)           │
│  export_.d    │ Export/verification capabilities             │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                Existing Infrastructure                       │
├─────────────────────────────────────────────────────────────┤
│  IntegrityValidator  │ BLAKE3-HMAC from security module     │
│  Blake3             │ Fast cryptographic hashing             │
│  BuildProof         │ Mathematical correctness proofs        │
└─────────────────────────────────────────────────────────────┘
```

## Security

- **Signing**: BLAKE3-HMAC with workspace-derived keys
- **Integrity**: Content-addressable hashes for all artifacts
- **Non-repudiation**: Timestamped attestations

## Integration

### CI/CD

Provenance is automatically generated when `BLDR_PROVENANCE_ENABLED=true`:

```yaml
# GitHub Actions
- name: Build with provenance
  run: bldr build --provenance
  env:
    BLDR_PROVENANCE_ENABLED: true
    BLDR_SLSA_LEVEL: L2
```

### Artifact Stores

Upload provenance alongside artifacts:

```bash
bldr build --provenance -o build.provenance.json
# Upload both artifact and provenance to registry
```


