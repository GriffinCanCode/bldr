# C++ Project Example

This example demonstrates the comprehensive C++ language support in Builder.

## Features Demonstrated

- **Auto-detection**: Compiler and build system auto-detection
- **C++ Standard**: Using C++17
- **Optimization**: O2 optimization level
- **Warnings**: All warnings enabled
- **Debug Info**: Enabled for development

## Building

```bash
# From the project root
bldr build cpp-app

# Or from this directory
bldr build
```

## Advanced Configuration

The Builderfile supports many advanced C++ features:

### Static Analysis
```d
cpp: {
    analyzer: "clang-tidy";
}
```

### Code Formatting
```d
cpp: {
    format: true;
    formatStyle: "LLVM";
}
```

### Sanitizers (Debug Builds)
```d
cpp: {
    sanitizers: ["address", "undefined"];
}
```

### Link-Time Optimization (Release Builds)
```d
cpp: {
    optimization: "o3";
    lto: "full";
}
```

### Build System Integration
```d
cpp: {
    buildSystem: "cmake";
    cmakeGenerator: "Ninja";
}
```

### Cross-Compilation
```d
cpp: {
    cross: {
        targetTriple: "arm-linux-gnueabihf";
    };
}
```

## See Also

- [C++ Language Support Documentation](../../source/languages/compiled/cpp/README.md)
- [Builder DSL Reference](../../docs/DSL.md)

