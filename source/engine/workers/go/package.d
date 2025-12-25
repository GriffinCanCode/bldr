module engine.workers.go;

/// Go Persistent Worker
/// 
/// Keeps Go build cache warm for faster builds.
/// Speedup: 2-5x by maintaining:
/// - Build cache
/// - Module cache
/// - Type checking state
/// 
/// Supports:
/// - go build - compile packages
/// - go test - run tests
/// - go vet - static analysis
/// - go fmt - formatting

public import engine.workers.go.worker;


