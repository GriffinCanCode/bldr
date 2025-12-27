# Language Handler Refactoring Blueprint

## Architecture Overview

The refactored language handler system follows a hierarchical base class pattern:

```
languages/base/                    ← Universal base classes
├── base.d                         ← BaseLanguageHandler (interface + core impl)
├── types.d                        ← Shared types (BuildErrorCode, OptLevel, etc.)
├── config.d                       ← BaseConfig, CompiledConfig, GPUConfig
├── compiled.d                     ← BaseCompiledHandler (compile→link workflow)
├── mixins.d                       ← CachingHandlerMixin, etc.
└── package.d

languages/<category>/              ← Category-specific base classes
├── base.d                         ← Base handler for that category
├── <language>/                    ← Individual language implementations
│   ├── core/
│   │   ├── handler.d              ← Extends category base
│   │   └── package.d
│   └── package.d
└── package.d
```

### Category Layout Examples

```
languages/gpu/                     ← GPU languages (CUDA, Metal, ROCm)
├── base.d                         ← BaseGPUHandler extends BaseCompiledHandler
├── cuda/core/handler.d            ← CUDAHandler extends BaseGPUHandler
├── metal/core/handler.d           ← MetalHandler extends BaseGPUHandler
└── rocm/core/handler.d            ← ROCmHandler extends BaseGPUHandler

languages/scripting/               ← Scripting languages (Python, Ruby, Go, etc.)
├── base.d                         ← BaseScriptingHandler (to be created)
├── python/core/handler.d          ← PythonHandler extends BaseScriptingHandler
└── ruby/core/handler.d            ← RubyHandler extends BaseScriptingHandler

languages/jvm/                     ← JVM languages (Java, Kotlin, Scala)
├── base.d                         ← BaseJVMHandler (to be created)
├── java/core/handler.d            ← JavaHandler extends BaseJVMHandler
└── kotlin/core/handler.d          ← KotlinHandler extends BaseJVMHandler
```

---

## Line Count Comparison (GPU Example)

| Handler | Before | After | Reduction |
|---------|--------|-------|-----------|
| CUDA handler.d | 755 lines | 286 lines | 62% |
| Metal handler.d | 306 lines | 282 lines | 8% |
| ROCm handler.d | 390 lines | 211 lines | 46% |
| CUDA config.d | ~200 lines | 0 (deleted) | 100% |
| Metal config.d | ~100 lines | 0 (deleted) | 100% |
| ROCm config.d | ~120 lines | 0 (deleted) | 100% |
| **Shared base.d** | N/A | 405 lines | Reusable |
| **Total** | ~1,871 lines | ~1,184 lines | **37%** |

---

## Conversion Steps

### Step 1: Identify the Category

Determine which base class your handler should extend:

| Category | Base Class | Use For |
|----------|------------|---------|
| `BaseLanguageHandler` | Universal | All handlers inherit this |
| `BaseCompiledHandler` | Compiled langs | C++, Rust, D, Swift, Zig |
| `BaseGPUHandler` | GPU compute | CUDA, Metal, ROCm |
| `BaseScriptingHandler` | Interpreted | Python, Ruby, Go, PHP |
| `BaseJVMHandler` | JVM langs | Java, Kotlin, Scala |
| `BaseWebHandler` | Web langs | TypeScript, JavaScript |

### Step 2: Create Category Base (if needed)

If the category base doesn't exist, create it at `languages/<category>/base.d`:

```d
module languages.<category>.base;

import languages.base;  // Import core base classes

abstract class Base<Category>Handler : BaseCompiledHandler  // or BaseLanguageHandler
{
    // Category-specific shared functionality
    
    // Abstract methods for subclasses to implement
    protected abstract string detectToolkit(...);
    protected abstract string[] buildCompileCmd(...);
}
```

### Step 3: Refactor the Handler

Replace verbose handler implementation with concise override:

#### Before (Verbose):
```d
class MyHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"mylang";
    
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
    {
        // 200+ lines of:
        // - Config parsing
        // - Toolkit detection  
        // - Directory setup
        // - Source iteration
        // - Compilation loop
        // - Linking
        // - Test running
        // - Dependency recording
    }
    
    // 100+ lines of config parsing
    private MyConfig parseConfig(in Target target) { ... }
    
    // 50+ lines of output resolution
    override string[] getOutputs(...) { ... }
}
```

#### After (Concise):
```d
class MyHandler : BaseCategoryHandler
{
    override protected string languageId() const pure nothrow => "mylang";
    override protected string[] configKeys() const pure nothrow => ["mylang", "myConfig"];
    override protected string toolkitNotFoundError() const pure nothrow => "...";
    
    override protected string detectToolkit(Config config) @system
    {
        // Just the detection logic, ~20 lines
    }
    
    override protected string[] buildCompileCmd(...) pure nothrow
    {
        // Just command building, ~30 lines
    }
    
    // Everything else inherited from base!
}
```

### Step 4: Delete Legacy Config

Remove the old `<language>/core/config.d` file. Config is now:
- Universal fields: `languages.base.config.BaseConfig`
- Compiled fields: `languages.base.config.CompiledConfig`
- GPU fields: `languages.base.config.GPUConfig`

Language-specific enum values stay in the handler.

### Step 5: Update Package Files

Update module paths in all package.d files:

```d
module languages.<category>.<language>.core;
public import languages.<category>.<language>.core.handler;
```

### Step 6: Update Registry

Update `engine/runtime/services/registry/handler.d`:

```d
case TargetLanguage.MyLang:
    import languages.<category>.<language> : MyHandler;
    return new MyHandler();
```

---

## What Moves to Base Classes

### Universal (in `languages/base/`)

| Feature | Location |
|---------|----------|
| Error codes | `types.d` → `BuildErrorCode` enum |
| Build metrics | `types.d` → `BuildMetrics` struct |
| Progress callbacks | `types.d` → `ProgressCallback` alias |
| Optimization levels | `types.d` → `OptLevel` enum |
| Warning levels | `types.d` → `WarningLevel` enum |
| Sanitizers | `types.d` → `Sanitizer` enum |
| Cross-compile config | `types.d` → `CrossCompileConfig` struct |
| Base config fields | `config.d` → `BaseConfig` struct |
| Compiled config | `config.d` → `CompiledConfig` struct |
| GPU config | `config.d` → `GPUConfig` struct |
| Tool detection | `compiled.d` → `detectTool()` |
| Compiler flags | `compiled.d` → `buildCompilerFlags()` |
| Linker flags | `compiled.d` → `buildLinkerFlags()` |
| File caching | `compiled.d` → `compileFileWithCaching()` |
| Output resolution | `compiled.d` → `resolveOutputPath()` |
| Dependency parsing | `compiled.d` → `parseDependencyFile()` |
| Include parsing | `compiled.d` → `parseIncludes()` |

### Category-Specific (in `languages/<category>/base.d`)

| Category | Features in Base |
|----------|------------------|
| GPU | Device/host separation, arch flags, toolkit detection pattern |
| Scripting | Venv setup, linting, formatting, type checking, package managers |
| JVM | Maven/Gradle detection, classpath building, JUnit test runner |
| Web | Bundler integration, source maps, declaration generation |

---

## What Stays in Individual Handlers

Each handler implements only what's unique:

1. **Language ID** - `languageId()` returns "cuda", "python", etc.
2. **Config keys** - `configKeys()` returns ["cuda", "cudaConfig"]
3. **Toolkit detection** - Specific paths/env vars for that tool
4. **Command building** - The actual compiler/linker invocation
5. **Output naming** - File extensions specific to that language
6. **Language-specific enums** - E.g., `MetalPlatform`, `CUDAOutputType`

---

## Template: Converting a Compiled Language Handler

```d
module languages.<category>.<language>.core.handler;

import languages.base;
import languages.<category>.base;  // If category base exists
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.logging;
import engine.caching.actions.action;

class <Language>Handler : Base<Category>Handler
{
    this() { super(null); }
    
    // ===== Required Overrides =====
    
    override protected string languageId() const pure nothrow => "<language>";
    
    override protected string[] configKeys() const pure nothrow => 
        ["<language>", "<language>Config"];
    
    override protected string toolkitNotFoundError() const pure nothrow =>
        "<Language> toolkit not found. Install from: <url>";
    
    override protected string detectToolkit(<Category>Config config) @system
    {
        // Check config path
        // Check environment variable
        // Check common paths
        // Fall back to PATH search
    }
    
    // ===== Optional Overrides =====
    
    // Only if category base doesn't handle it
    override protected string[] buildCompileCmd(...) pure nothrow { ... }
    override protected string[] buildLinkCmd(...) pure nothrow { ... }
    override protected string getOutputName(...) const pure nothrow { ... }
}
```

---

## Remaining Handlers to Convert

### Priority 1: Scripting Languages
- [ ] Python (most complex, good test case)
- [ ] Ruby
- [ ] Go
- [ ] PHP
- [ ] Perl
- [ ] Lua
- [ ] R
- [ ] Elixir

### Priority 2: Compiled Languages  
- [ ] C++ (already has good structure)
- [ ] Rust
- [ ] D
- [ ] Swift
- [ ] Zig
- [ ] Nim
- [ ] Haskell
- [ ] OCaml

### Priority 3: JVM Languages
- [ ] Java
- [ ] Kotlin
- [ ] Scala

### Priority 4: .NET Languages
- [ ] C#
- [ ] F#

### Priority 5: Web Languages ✅
- [x] TypeScript
- [x] JavaScript
- [x] CSS
- [x] Elm

---

## Universal Features Now Available

Once a handler extends the appropriate base class, it automatically gets:

1. **Error Codes** - `BuildErrorCode` enum with 50+ standardized codes
2. **Build Metrics** - Timing, cache hits, file counts
3. **Progress Reporting** - Phase-based progress callbacks
4. **Structured Logging** - Consistent log format
5. **Action Caching** - Per-file compile caching
6. **Dependency Recording** - Incremental build support
7. **Cross-Compilation** - Unified cross-compile config
8. **Verbosity Levels** - Quiet/Normal/Verbose/Debug
9. **Dry Run Mode** - Show what would be built
10. **Force Rebuild** - Bypass cache
11. **Parallel Compilation** - Jobs configuration
12. **Warning Filtering** - Suppress specific warnings
13. **Warnings as Errors** - Strict mode

To use a feature, just access it from the base class or config:

```d
// In any handler extending BaseCompiledHandler:
if (config.compiled.base.dryRun)
    structuredLog.info("dry_run_mode").emit();

auto result = createError("Compile failed", BuildErrorCode.CompilationFailed);
```

