module tests.unit.workers.language_workers_test;

import std.stdio : writeln;
import std.conv : to;
import std.datetime : seconds, minutes;
import std.algorithm : startsWith;
import core.time : Duration;

// JVM Workers
import engine.workers.jvm.worker;

// TypeScript Workers
import engine.workers.typescript.worker;

// Rust Workers
import engine.workers.rust.worker;

// Go Workers
import engine.workers.go.worker;

// Python Workers
import engine.workers.python.worker;

// ==================== JVM Worker Tests ====================

/// Test JVMWorkerConfig defaults
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.jvm - JVMWorkerConfig defaults");
    
    JVMWorkerConfig cfg;
    
    assert(cfg.compiler == JVMCompiler.Javac, "Default compiler should be javac");
    assert(cfg.startupTimeout == seconds(30), "Default startup timeout");
    assert(cfg.requestTimeout == minutes(5), "Default request timeout");
    assert(cfg.maxHeapMB == 2048, "Default max heap");
    assert(cfg.enableIncrementalCompilation, "Incremental should be enabled");
    
    writeln("\x1b[32m  ✓ JVMWorkerConfig defaults correct\x1b[0m");
}

/// Test JVMWorkerFactory worker types
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.jvm - JVMWorkerFactory types");
    
    foreach (compiler; [JVMCompiler.Javac, JVMCompiler.Kotlinc, JVMCompiler.Scalac, JVMCompiler.Groovyc])
    {
        JVMWorkerConfig cfg;
        cfg.compiler = compiler;
        auto factory = new JVMWorkerFactory(cfg);
        
        auto workerType = factory.workerType();
        assert(workerType.startsWith("jvm-"), "Worker type should start with jvm-");
    }
    
    // Specific type checks
    JVMWorkerConfig javacCfg;
    javacCfg.compiler = JVMCompiler.Javac;
    assert(new JVMWorkerFactory(javacCfg).workerType() == "jvm-javac", "Javac type");
    
    JVMWorkerConfig kotlincCfg;
    kotlincCfg.compiler = JVMCompiler.Kotlinc;
    assert(new JVMWorkerFactory(kotlincCfg).workerType() == "jvm-kotlinc", "Kotlinc type");
    
    writeln("\x1b[32m  ✓ JVMWorkerFactory types correct\x1b[0m");
}

/// Test JVM CompilationResult
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.jvm - CompilationResult");
    
    auto success = CompilationResult(true, "Compiled 5 files", 150, false, ["Main.class"]);
    assert(success.success, "Should be success");
    assert(success.executionTimeMs == 150, "Exec time should match");
    
    auto failure = CompilationResult(false, "error: cannot find symbol", 50, false, []);
    assert(!failure.success, "Should be failure");
    
    writeln("\x1b[32m  ✓ JVM CompilationResult works\x1b[0m");
}

// ==================== TypeScript Worker Tests ====================

/// Test TSWorkerConfig defaults
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.typescript - TSWorkerConfig defaults");
    
    TSWorkerConfig cfg;
    
    assert(cfg.compiler == TSCompilerType.TSC, "Default compiler should be tsc");
    assert(cfg.startupTimeout == seconds(15), "Default startup timeout");
    assert(cfg.requestTimeout == minutes(5), "Default request timeout");
    assert(cfg.incremental, "Incremental should be enabled");
    assert(cfg.maxOldSpaceMB == 4096, "Default max old space");
    
    writeln("\x1b[32m  ✓ TSWorkerConfig defaults correct\x1b[0m");
}

/// Test TypeScriptWorkerFactory worker types
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.typescript - TypeScriptWorkerFactory types");
    
    foreach (compiler; [TSCompilerType.TSC, TSCompilerType.SWC, TSCompilerType.ESBuild, TSCompilerType.Bun])
    {
        TSWorkerConfig cfg;
        cfg.compiler = compiler;
        auto factory = new TypeScriptWorkerFactory(cfg);
        
        auto workerType = factory.workerType();
        assert(workerType.startsWith("ts-"), "Worker type should start with ts-");
    }
    
    TSWorkerConfig tscCfg;
    tscCfg.compiler = TSCompilerType.TSC;
    assert(new TypeScriptWorkerFactory(tscCfg).workerType() == "ts-tsc", "TSC type");
    
    TSWorkerConfig swcCfg;
    swcCfg.compiler = TSCompilerType.SWC;
    assert(new TypeScriptWorkerFactory(swcCfg).workerType() == "ts-swc", "SWC type");
    
    writeln("\x1b[32m  ✓ TypeScriptWorkerFactory types correct\x1b[0m");
}

/// Test TSCompileOptions defaults
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.typescript - TSCompileOptions defaults");
    
    TSCompileOptions opts;
    
    assert(opts.target == "ES2020", "Default target");
    assert(opts.module_ == "commonjs", "Default module");
    assert(opts.sourceMap, "Source maps enabled by default");
    assert(!opts.declaration, "Declarations disabled by default");
    assert(opts.strict, "Strict enabled by default");
    
    writeln("\x1b[32m  ✓ TSCompileOptions defaults correct\x1b[0m");
}

/// Test TSDiagnostic
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.typescript - TSDiagnostic");
    
    auto diag = TSDiagnostic("src/app.ts", 10, 5, "Property does not exist", "error");
    
    assert(diag.file == "src/app.ts", "File should match");
    assert(diag.line == 10, "Line should match");
    assert(diag.column == 5, "Column should match");
    assert(diag.severity == "error", "Severity should match");
    
    writeln("\x1b[32m  ✓ TSDiagnostic works\x1b[0m");
}

// ==================== Rust Worker Tests ====================

/// Test RustWorkerConfig defaults
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.rust - RustWorkerConfig defaults");
    
    RustWorkerConfig cfg;
    
    assert(cfg.compiler == RustCompiler.Cargo, "Default compiler should be cargo");
    assert(cfg.startupTimeout == seconds(30), "Default startup timeout");
    assert(cfg.requestTimeout == minutes(10), "Default request timeout");
    assert(cfg.incremental, "Incremental should be enabled");
    assert(!cfg.release, "Release should be disabled by default");
    
    writeln("\x1b[32m  ✓ RustWorkerConfig defaults correct\x1b[0m");
}

/// Test RustWorkerFactory worker types
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.rust - RustWorkerFactory types");
    
    foreach (compiler; [RustCompiler.Cargo, RustCompiler.CargoCheck, RustCompiler.Rustc, RustCompiler.Clippy])
    {
        RustWorkerConfig cfg;
        cfg.compiler = compiler;
        auto factory = new RustWorkerFactory(cfg);
        
        auto workerType = factory.workerType();
        assert(workerType.startsWith("rust-"), "Worker type should start with rust-");
    }
    
    RustWorkerConfig cargoCfg;
    cargoCfg.compiler = RustCompiler.Cargo;
    assert(new RustWorkerFactory(cargoCfg).workerType() == "rust-cargo", "Cargo type");
    
    RustWorkerConfig checkCfg;
    checkCfg.compiler = RustCompiler.CargoCheck;
    assert(new RustWorkerFactory(checkCfg).workerType() == "rust-cargo-check", "Cargo check type");
    
    RustWorkerConfig clippyCfg;
    clippyCfg.compiler = RustCompiler.Clippy;
    assert(new RustWorkerFactory(clippyCfg).workerType() == "rust-clippy", "Clippy type");
    
    writeln("\x1b[32m  ✓ RustWorkerFactory types correct\x1b[0m");
}

/// Test RustDiagnostic
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.rust - RustDiagnostic");
    
    auto diag = RustDiagnostic("src/lib.rs", 25, 10, "unused variable", "warning");
    
    assert(diag.file == "src/lib.rs", "File should match");
    assert(diag.line == 25, "Line should match");
    assert(diag.column == 10, "Column should match");
    assert(diag.level == "warning", "Level should match");
    
    writeln("\x1b[32m  ✓ RustDiagnostic works\x1b[0m");
}

// ==================== Go Worker Tests ====================

/// Test GoWorkerConfig defaults
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.go - GoWorkerConfig defaults");
    
    GoWorkerConfig cfg;
    
    assert(cfg.compiler == GoCompiler.Build, "Default compiler should be build");
    assert(cfg.startupTimeout == seconds(15), "Default startup timeout");
    assert(cfg.requestTimeout == minutes(5), "Default request timeout");
    assert(!cfg.race, "Race detector should be disabled");
    assert(cfg.trimpath, "Trimpath should be enabled");
    
    writeln("\x1b[32m  ✓ GoWorkerConfig defaults correct\x1b[0m");
}

/// Test GoWorkerFactory worker types
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.go - GoWorkerFactory types");
    
    foreach (compiler; [GoCompiler.Build, GoCompiler.Test, GoCompiler.Vet, GoCompiler.Fmt])
    {
        GoWorkerConfig cfg;
        cfg.compiler = compiler;
        auto factory = new GoWorkerFactory(cfg);
        
        auto workerType = factory.workerType();
        assert(workerType.startsWith("go-"), "Worker type should start with go-");
    }
    
    GoWorkerConfig buildCfg;
    buildCfg.compiler = GoCompiler.Build;
    assert(new GoWorkerFactory(buildCfg).workerType() == "go-build", "Build type");
    
    GoWorkerConfig testCfg;
    testCfg.compiler = GoCompiler.Test;
    assert(new GoWorkerFactory(testCfg).workerType() == "go-test", "Test type");
    
    writeln("\x1b[32m  ✓ GoWorkerFactory types correct\x1b[0m");
}

/// Test GoDiagnostic
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.go - GoDiagnostic");
    
    auto diag = GoDiagnostic("main.go", 15, 8, "undefined: fmt", "error");
    
    assert(diag.file == "main.go", "File should match");
    assert(diag.line == 15, "Line should match");
    assert(diag.column == 8, "Column should match");
    assert(diag.level == "error", "Level should match");
    
    writeln("\x1b[32m  ✓ GoDiagnostic works\x1b[0m");
}

// ==================== Python Worker Tests ====================

/// Test PythonWorkerConfig defaults
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.python - PythonWorkerConfig defaults");
    
    PythonWorkerConfig cfg;
    
    assert(cfg.tool == PythonTool.Mypy, "Default tool should be mypy");
    assert(cfg.startupTimeout == seconds(30), "Default startup timeout");
    assert(cfg.requestTimeout == minutes(5), "Default request timeout");
    assert(cfg.daemon, "Daemon should be enabled");
    assert(cfg.incremental, "Incremental should be enabled");
    
    writeln("\x1b[32m  ✓ PythonWorkerConfig defaults correct\x1b[0m");
}

/// Test PythonWorkerFactory worker types
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.python - PythonWorkerFactory types");
    
    foreach (tool; [PythonTool.Mypy, PythonTool.Ruff, PythonTool.Pylint, PythonTool.Black, PythonTool.Pytest])
    {
        PythonWorkerConfig cfg;
        cfg.tool = tool;
        auto factory = new PythonWorkerFactory(cfg);
        
        auto workerType = factory.workerType();
        assert(workerType.startsWith("python-"), "Worker type should start with python-");
    }
    
    PythonWorkerConfig mypyCfg;
    mypyCfg.tool = PythonTool.Mypy;
    assert(new PythonWorkerFactory(mypyCfg).workerType() == "python-mypy", "Mypy type");
    
    PythonWorkerConfig ruffCfg;
    ruffCfg.tool = PythonTool.Ruff;
    assert(new PythonWorkerFactory(ruffCfg).workerType() == "python-ruff", "Ruff type");
    
    PythonWorkerConfig pytestCfg;
    pytestCfg.tool = PythonTool.Pytest;
    assert(new PythonWorkerFactory(pytestCfg).workerType() == "python-pytest", "Pytest type");
    
    writeln("\x1b[32m  ✓ PythonWorkerFactory types correct\x1b[0m");
}

/// Test PythonDiagnostic
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers.python - PythonDiagnostic");
    
    auto diag = PythonDiagnostic("app.py", 42, 0, "Missing return statement", "E1111", "error");
    
    assert(diag.file == "app.py", "File should match");
    assert(diag.line == 42, "Line should match");
    assert(diag.code == "E1111", "Code should match");
    assert(diag.level == "error", "Level should match");
    
    writeln("\x1b[32m  ✓ PythonDiagnostic works\x1b[0m");
}

// ==================== Cross-Language Tests ====================

/// Test all worker factories implement IWorkerFactory
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers - All factories implement IWorkerFactory");
    
    import engine.workers.pool.manager : IWorkerFactory;
    
    // JVM
    auto jvmFactory = new JVMWorkerFactory();
    assert(cast(IWorkerFactory)jvmFactory !is null, "JVM factory should implement IWorkerFactory");
    
    // TypeScript
    auto tsFactory = new TypeScriptWorkerFactory();
    assert(cast(IWorkerFactory)tsFactory !is null, "TS factory should implement IWorkerFactory");
    
    // Rust
    auto rustFactory = new RustWorkerFactory();
    assert(cast(IWorkerFactory)rustFactory !is null, "Rust factory should implement IWorkerFactory");
    
    // Go
    auto goFactory = new GoWorkerFactory();
    assert(cast(IWorkerFactory)goFactory !is null, "Go factory should implement IWorkerFactory");
    
    // Python
    auto pyFactory = new PythonWorkerFactory();
    assert(cast(IWorkerFactory)pyFactory !is null, "Python factory should implement IWorkerFactory");
    
    writeln("\x1b[32m  ✓ All factories implement IWorkerFactory\x1b[0m");
}

/// Test worker type uniqueness
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m workers - Worker type uniqueness");
    
    import engine.workers.pool.manager : IWorkerFactory;
    
    IWorkerFactory[] factories = [
        new JVMWorkerFactory(),
        new TypeScriptWorkerFactory(),
        new RustWorkerFactory(),
        new GoWorkerFactory(),
        new PythonWorkerFactory()
    ];
    
    string[] types;
    foreach (factory; factories)
    {
        auto wtype = factory.workerType();
        assert(!types.canFind(wtype), "Worker type should be unique: " ~ wtype);
        types ~= wtype;
    }
    
    assert(types.length == 5, "Should have 5 unique types");
    
    writeln("\x1b[32m  ✓ Worker types are unique\x1b[0m");
}

private bool canFind(T)(T[] arr, T elem)
{
    foreach (e; arr)
        if (e == elem) return true;
    return false;
}


