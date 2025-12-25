/**
 * Engine Package - Core Build Execution & Performance
 * 
 * This package contains the core build execution engine and performance-critical systems.
 * 
 * Modules:
 * - runtime: Build execution, hermetic builds, remote execution, recovery, watch mode
 * - graph: Dependency graph construction and management
 * - compilation: Incremental compilation engine
 * - caching: Multi-tier caching (local, action, remote, distributed)
 * - distributed: Distributed build execution with work-stealing
 * - provenance: SLSA-compliant build provenance for supply chain security
 */
module engine;

public import engine.runtime;
public import engine.graph;
public import engine.compilation;
public import engine.caching;
public import engine.distributed;
public import engine.provenance;

