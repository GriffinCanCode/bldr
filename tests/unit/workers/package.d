module tests.unit.workers;

/// Persistent Workers Unit Tests
/// 
/// Comprehensive tests for the multi-language persistent worker system.
/// 
/// Test Coverage:
/// - Base worker infrastructure (base_test.d)
/// - Protocol serialization/deserialization (protocol_test.d)
/// - All language workers: JVM, TypeScript, Rust, Go, Python (language_workers_test.d)
/// - Service lifecycle and configuration (service_test.d)
/// 
/// Total: 59 unit tests

public import tests.unit.workers.base_test;
public import tests.unit.workers.protocol_test;
public import tests.unit.workers.language_workers_test;
public import tests.unit.workers.service_test;


