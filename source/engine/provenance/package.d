/**
 * SLSA Build Provenance
 * 
 * Software supply chain security through cryptographically signed
 * build provenance attestations. Implements SLSA (Supply-chain Levels
 * for Software Artifacts) v1.0 specification.
 * 
 * Features:
 * - SLSA v1.0 compliant provenance format
 * - BLAKE3-HMAC signed attestations (DSSE envelope)
 * - In-toto compatible statements
 * - Multiple SLSA level support (L1-L3)
 * - Non-intrusive build integration
 * 
 * Quick Start:
 * ---
 * import engine.provenance;
 * 
 * // Generate provenance during build
 * auto gen = ProvenanceGenerator.create();
 * gen.startBuild(hermetic: true);
 * gen.addMaterial("src/main.d");
 * gen.addOutput("bin/app");
 * 
 * auto provResult = gen.finalize();
 * if (provResult.isOk)
 * {
 *     auto prov = provResult.unwrap();
 *     
 *     // Sign and export
 *     auto signer = ProvenanceSigner.fromWorkspace(".");
 *     auto envelope = signer.sign(prov).unwrap();
 *     
 *     // Write to file
 *     ProvenanceExporter.writeToFile(prov, "build.provenance.json");
 *     
 *     // Human-readable summary
 *     writeln(ProvenanceExporter.toSummary(prov));
 * }
 * ---
 * 
 * SLSA Levels:
 * - L1: Provenance exists (automatic with bldr)
 * - L2: Hosted build platform (bldr on CI)
 * - L3: Hardened builds (hermetic mode)
 * 
 * Verification:
 * ---
 * auto verifier = ProvenanceVerifier.create(".", SLSALevel.L2);
 * auto result = verifier.verifyFile("build.provenance.json");
 * if (result.isOk && result.unwrap().passed())
 *     writeln("✓ Provenance verified");
 * ---
 */
module engine.provenance;

// Core types
public import engine.provenance.types;

// Provenance generation
public import engine.provenance.generator;

// Cryptographic signing
public import engine.provenance.signer;

// Export and verification
public import engine.provenance.export_;


