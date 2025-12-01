# Builder Programmability Examples

Comprehensive examples demonstrating the three-tier programmability system.

## Overview

Builder provides three levels of programmability to match your needs:

1. **Tier 1 - Functional DSL**: Variables, functions, loops, conditionals
2. **Tier 2 - D Macros**: Full D language power for complex logic
3. **Tier 3 - Plugins**: External tool integration (already exists)

## Directory Structure

```
programmability/
├── tier1-simple/          # Basic variables and loops
├── tier1-functions/       # Functions and macros
├── tier2-macros/          # D-based macros
├── tier3-plugin/          # Plugin integration
└── combined/              # All three tiers together
```

## Tier 1: Functional DSL

**Handles 90% of use cases** - Simple, declarative, type-safe.

### Example: Variables and Loops

```d
// tier1-simple/Builderfile
let packages = ["core", "utils", "api"];

for pkg in packages {
    target(pkg) {
        type: library;
        sources: ["lib/" + pkg + "/**/*.py"];
    }
}
```

**Features:**
- Variables: `let`, `const`
- String interpolation: `"${version}"`
- Conditionals: `if`/`else`
- Loops: `for`/`in`
- Functions: `fn name(args) { ... }`
- Macros: `macro name(args) { ... }`
- Built-ins: `glob()`, `env()`, `platform()`, etc.

### When to use:
- Multi-platform builds
- Target generation from lists
- Conditional compilation
- Simple code reuse

### Run example:
```bash
cd tier1-simple
bldr build :app
```

## Tier 2: D Macros

**Handles 9% of advanced cases** - Full D language, compile-time safe.

### Example: Microservice Generator

```d
// tier2-macros/Builderfile.d
Target[] generateMicroservices() {
    ServiceSpec[] services = [...];  // Complex config
    
    return services.map!(svc =>
        TargetBuilder.create(svc.name)
            .type(TargetType.Executable)
            .language("go")
            .sources(["services/" ~ svc.name ~ "/**/*.go"])
            .build()
    ).array;
}
```

**Features:**
- Full D language access
- Templates and mixins
- Compile-time validation
- Type-safe generation
- File system introspection
- Complex algorithms

### When to use:
- Complex target generation logic
- Code generation pipelines
- Platform matrix builds
- Dependency graph algorithms
- File structure introspection

### Run example:
```bash
cd tier2-macros
dmd Builderfile.d -of=generator
./generator  # Outputs JSON targets
```

## Tier 3: Plugins

**Handles 1% of integration cases** - External tools, process isolated.

### Example: Docker + Kubernetes

```d
// tier3-plugin/Builderfile
target("docker-image") {
    type: custom;
    plugin: "docker";
    config: {
        "image": "myapp:latest",
        "platform": "linux/amd64,linux/arm64"
    };
}
```

**Features:**
- Custom target types
- External tool integration
- Build lifecycle hooks
- Process isolation
- Language agnostic

### When to use:
- Docker/container builds
- Cloud deployments (Terraform, Kubernetes)
- Code analysis (SonarQube, CodeClimate)
- Notification systems
- Custom build steps

### Run example:
```bash
cd tier3-plugin
bldr build :docker-image
```

## Combined: All Three Tiers

The `combined/` example shows all three tiers working together seamlessly.

**Architecture:**
```
Tier 1 (DSL)
    ├─ Variables and conditionals
    ├─ Calls Tier 2 (D macros)
    │   └─ Complex generation logic
    ├─ Uses Tier 2 output
    └─ Calls Tier 3 (Plugins)
        └─ External tools
```

**Example workflow:**
1. **Tier 1**: Define base configuration, packages, flags
2. **Tier 2**: Call D macro to generate microservices with complex logic
3. **Tier 1**: Use generated service list in Tier 1 loops
4. **Tier 3**: Build Docker images and deploy via plugins
5. **Tier 1**: Assemble final application

### Run example:
```bash
cd combined
bldr build :app
```

## Comparison

| Feature | Tier 1 | Tier 2 | Tier 3 |
|---------|--------|--------|--------|
| **Complexity** | Low | Medium | High |
| **Learning Curve** | Easy | Moderate | Easy |
| **Type Safety** | Static | Compile-time | Runtime |
| **Performance** | Parse-time | Compile-time | Runtime |
| **Use Cases** | 90% | 9% | 1% |
| **When to Use** | Common patterns | Complex logic | External tools |

## Best Practices

### 1. Start Simple (Tier 1)
```d
// Good: Simple and readable
let packages = ["a", "b", "c"];
for pkg in packages {
    target(pkg) { ... }
}

// Avoid: Overcomplicating simple cases
import ComplexMacro;  // Overkill for simple loops
```

### 2. Use Right Tool for the Job

**Tier 1 for:**
- Variable definitions
- Simple loops and conditionals
- Platform detection
- Code reuse with functions

**Tier 2 for:**
- Complex algorithms
- File system introspection
- Type-safe generation
- Large-scale code generation

**Tier 3 for:**
- Docker/containers
- Cloud deployments
- External analysis tools
- Custom build systems

### 3. Compose Tiers

```d
// Tier 1: Configuration
let env = env("ENV", "dev");

// Tier 2: Complex generation
import macros;
let services = generateServices();  // D macro

// Tier 1: Use Tier 2 output
for svc in services {
    target(svc.name + "-test") { ... }
}

// Tier 3: External tools
target("deploy") {
    plugin: "kubernetes";
    deps: services.map(|s| ":" + s);
}
```

### 4. Keep Build Files Maintainable

**Good:**
```d
// Clear, organized, commented
let version = "1.0.0";  // Version for all artifacts

fn createService(name) {  // Reusable function
    return { ... };
}

// Generate services
for svc in ["auth", "api"] {
    target(svc) = createService(svc);
}
```

**Avoid:**
```d
// Cryptic, unreadable
let x=["a","b"];for i in x{target(i){...}}  // No spacing
import SuperComplexMacro;  // Overkill
doEverythingInOneMacro();  // Not modular
```

## Testing

Test each tier independently:

### Tier 1
```bash
# Test DSL parsing and evaluation
builder check tier1-simple/Builderfile

# Dry-run to see generated targets
bldr build --dry-run :all
```

### Tier 2
```bash
# Compile D macro
dmd tier2-macros/Builderfile.d

# Test execution
./Builderfile | jq .  # View JSON output
```

### Tier 3
```bash
# Test plugin availability
builder plugin list

# Test plugin execution
bldr build :docker-image --verbose
```

## Migration Guide

### From Pure Declarative → Tier 1

**Before:**
```d
target("core") { ... }
target("api") { ... }
target("cli") { ... }
// Repetitive!
```

**After:**
```d
let packages = ["core", "api", "cli"];
for pkg in packages {
    target(pkg) { ... }
}
```

### From Tier 1 → Tier 2

**When Tier 1 Gets Complex:**
```d
// Tier 1 becomes unwieldy
let services = [...];  // 50 lines of config
// Complex nested loops
for svc in services {
    for platform in platforms {
        for arch in arches {
            // 100+ lines of logic
        }
    }
}
```

**Move to Tier 2:**
```d
// Builderfile.d - Clean, type-safe
Target[] generate() {
    return platformMatrix(services);  // D's power
}
```

### From Scripts → Tier 3 Plugins

**Before:**
```bash
# build.sh - Hard to integrate
docker build -t myapp .
kubectl apply -f k8s/
```

**After:**
```d
// Builderfile - Integrated
target("deploy") {
    plugin: "kubernetes";
    deps: [":docker-image"];
}
```

## Performance

### Tier 1: Parse-Time Evaluation
- **Speed**: Instant (< 10ms)
- **Overhead**: Zero runtime cost
- **Optimization**: Constant folding, dead code elimination

### Tier 2: Compile-Time or Cached
- **First Run**: ~1s (compilation)
- **Cached**: < 10ms
- **CTFE**: Instant (compile-time)

### Tier 3: Plugin Execution
- **Speed**: Depends on plugin
- **Overhead**: Process spawn (~50ms)
- **Isolation**: Full process isolation

## Troubleshooting

### Tier 1 Issues

**Undefined variable:**
```
Error: Undefined variable 'unknownVar'
Suggestion: Define with 'let unknownVar = ...'
```

**Type mismatch:**
```
Error: Cannot add string and number
Fix: Use str() to convert: "version-" + str(1)
```

### Tier 2 Issues

**Compilation failed:**
```bash
# Check D compiler
which ldc2

# Verbose compilation
bldr build --macro-verbose
```

**Import errors:**
```d
// Add import path
import builder.macros;  // Ensure builder.macros is in path
```

### Tier 3 Issues

**Plugin not found:**
```bash
# List available plugins
builder plugin list

# Install plugin
brew install builder-plugin-docker
```

## Further Reading

- [Tier 1 Documentation](../../source/config/scripting/README.md)
- [Tier 2 Documentation](../../source/config/macros/README.md)
- [Tier 3 Documentation](../../docs/architecture/plugins.md)
- [Architecture Overview](../../docs/architecture/programmability.md)

## Questions?

**Q: Which tier should I use?**  
A: Start with Tier 1. Move to Tier 2 only if logic is too complex. Use Tier 3 for external tools.

**Q: Can I mix tiers?**  
A: Yes! They integrate seamlessly. Use each tier for what it's best at.

**Q: Is it type-safe?**  
A: Yes! All tiers provide type safety. Tier 1 has runtime checks, Tier 2 has compile-time checks.

**Q: What about performance?**  
A: All tiers evaluate at build time, not runtime. Zero overhead in final binaries.

**Q: Can I share macros?**  
A: Yes! Publish D macros as packages, distribute plugins via Homebrew.

