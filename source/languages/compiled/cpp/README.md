# C/C++ Language Support

Comprehensive C/C++ build support with advanced compiler, build system, and tooling integration.

## Architecture

```
source/languages/compiled/cpp/
├── package.d             # Public exports
├── README.md             # This file
├── core/                 # Core handler and configuration
│   ├── handler.d         # Main build handler
│   ├── config.d          # Configuration types and enums
│   └── package.d         # Core module exports
├── analysis/             # Dependency analysis
│   ├── analysis.d        # Header dependency and template analysis
│   ├── incremental.d     # Incremental compilation analysis
│   └── package.d         # Analysis module exports
├── tooling/              # Compiler and tool detection
│   ├── tools.d           # Static analysis, formatting, sanitizers
│   └── package.d         # Tooling module exports
└── builders/             # Build strategies
    ├── package.d         # Builder exports
    ├── base.d            # Builder interface and factory
    ├── direct.d          # Direct compiler invocation
    ├── cmake.d           # CMake integration
    ├── make.d            # Make integration
    ├── ninja.d           # Ninja integration
    ├── bazel.d           # Bazel integration
    ├── meson.d           # Meson integration
    ├── xmake.d           # xmake integration
    └── incremental.d     # Incremental build support
```

## Features

### Core Capabilities

- **Multi-Compiler Support**: GCC, Clang, MSVC, Intel C++ Compiler, Custom compilers
- **Build System Integration**: CMake, Make, Ninja, Bazel, Meson, Xmake
- **Standard Versions**: C++98 through C++26, C89 through C23, GNU extensions
- **Output Types**: Executables, static libraries, shared libraries, object files, header-only
- **Cross-Compilation**: Target triple support with sysroot and toolchain prefix
- **Optimization Levels**: O0, O1, O2, O3, Os, Ofast, Og
- **Link-Time Optimization**: Thin LTO and Full LTO support

### Advanced Features

#### Static Analysis
- **Clang-Tidy**: Comprehensive static analysis with configurable checks
- **CppCheck**: Additional static analysis engine
- **PVS-Studio**: Commercial static analyzer (planned)
- **Coverity**: Enterprise static analysis (planned)

#### Code Quality
- **Clang-Format**: Automatic code formatting with customizable styles
- **Sanitizers**: 
  - AddressSanitizer (ASan) - Memory error detection
  - ThreadSanitizer (TSan) - Data race detection
  - MemorySanitizer (MSan) - Uninitialized memory detection
  - UndefinedBehaviorSanitizer (UBSan) - Undefined behavior detection
  - LeakSanitizer (LSan) - Memory leak detection
  - Hardware-assisted AddressSanitizer (HWASan)

#### Build Optimization
- **Precompiled Headers (PCH)**: Automatic PCH suggestion and benefit estimation
- **Unity Builds**: Combine source files for faster compilation
- **Parallel Compilation**: Multi-threaded builds with configurable job count
- **Header Dependency Analysis**: Transitive header tracking
- **Template Analysis**: Template usage detection and optimization

#### Development Tools
- **Code Coverage**: gcov, llvm-cov, lcov integration
- **Compile Commands**: Generate compile_commands.json for IDE integration
- **Color Diagnostics**: Colored compiler output
- **Time Reporting**: Compilation time breakdown
- **Warning Levels**: None, Default, Extra, All, Pedantic, Error

### Language Features Support
- **C++20 Modules**: Experimental module support
- **Coroutines**: C++20 coroutine support
- **Concepts**: C++20 concept support
- **Exceptions**: Configurable exception handling
- **RTTI**: Configurable runtime type information

## Configuration

### Basic Example

```d
target("my-app") {
    type: executable;
    language: cpp;
    sources: ["main.cpp", "utils.cpp"];
    cpp: {
        compiler: "clang";
        std: "c++20";
        optimization: "o3";
        warnings: "all";
        debugInfo: true;
    };
}
```

### Advanced Example

```d
target("high-perf-lib") {
    type: library;
    language: cpp;
    sources: glob("src/**/*.cpp");
    cpp: {
        compiler: "clang";
        std: "c++20";
        optimization: "o3";
        lto: "full";
        warnings: "error";
        
        // Optimization features
        pic: true;
        strip: false;
        
        // Include and library paths
        includeDirs: ["include", "third_party/include"];
        libDirs: ["lib"];
        libs: ["pthread", "dl"];
        
        // Defines
        defines: ["NDEBUG", "ENABLE_LOGGING"];
        
        // Static analysis
        analyzer: "clang-tidy";
        format: true;
        formatStyle: "Google";
        
        // Sanitizers (for debug builds)
        // sanitizers: ["address", "undefined"];
        
        // Precompiled headers
        pch: {
            strategy: "auto";
        };
        
        // Code coverage
        coverage: {
            enabled: false;
            tool: "lcov";
            outputDir: "coverage";
        };
    };
}
```

### Cross-Compilation Example

```d
target("arm-binary") {
    type: executable;
    language: cpp;
    sources: ["main.cpp"];
    cpp: {
        compiler: "clang";
        std: "c++17";
        cross: {
            targetTriple: "arm-linux-gnueabihf";
            sysroot: "/usr/arm-linux-gnueabihf";
        };
    };
}
```

### CMake Integration Example

```d
target("cmake-project") {
    type: executable;
    language: cpp;
    sources: ["src/main.cpp"];  // CMakeLists.txt detected automatically
    cpp: {
        buildSystem: "cmake";
        cmakeGenerator: "Ninja";
        cmakeBuildType: "Release";
        cmakeOptions: [
            "-DENABLE_TESTS=ON",
            "-DBUILD_SHARED_LIBS=OFF"
        ];
        compileCommands: true;  // Generate compile_commands.json
    };
}
```

## Configuration Reference

### Compiler Options
- `compiler`: auto, gcc, clang, msvc, intel, custom
- `customCompiler`: Path to custom compiler (when compiler=custom)
- `buildSystem`: none, auto, cmake, make, ninja, bazel, meson, xmake

### Standards
- `cppStandard`: c++98, c++03, c++11, c++14, c++17, c++20, c++23, c++26
- `cStandard`: c89, c90, c99, c11, c17, c23
- GNU extensions: gnu++XX, gnuXX

### Optimization
- `optLevel`: o0, o1, o2, o3, os, ofast, og
- `lto`: off, thin, full
- `debugInfo`: boolean
- `strip`: boolean

### Output
- `outputType`: executable, staticLib, sharedLib, object, headerOnly
- `output`: Output filename
- `objDir`: Intermediate object directory

### Paths and Flags
- `includeDirs`: Include directories array
- `libDirs`: Library directories array
- `libs`: Libraries to link array
- `sysLibs`: System libraries array
- `defines`: Preprocessor definitions array
- `compilerFlags`: Additional compiler flags array
- `linkerFlags`: Additional linker flags array

### Code Quality
- `warnings`: none, default, extra, all, pedantic, error
- `analyzer`: none, clang-tidy, cppcheck, pvs-studio, coverity
- `format`: boolean
- `formatStyle`: LLVM, Google, Chromium, Mozilla, WebKit, Microsoft, GNU, file

### Sanitizers
- `sanitizers`: Array of [address, thread, memory, ub, leak, hwaddress]

### Advanced Features
- `pic`: Position independent code
- `pie`: Position independent executable
- `exceptions`: Enable exceptions
- `rtti`: Enable RTTI
- `modules`: C++20 modules
- `coroutines`: C++20 coroutines
- `concepts`: C++20 concepts

### Build Options
- `jobs`: Parallel job count (0 = auto)
- `verbose`: Verbose output
- `colorDiagnostics`: Color output
- `timeReport`: Compilation time report
- `compileCommands`: Generate compile_commands.json

### Cross-Compilation
```d
cross: {
    targetTriple: "x86_64-linux-gnu";
    arch: "x86_64";
    os: "linux";
    sysroot: "/path/to/sysroot";
    prefix: "x86_64-linux-gnu-";
}
```

### Precompiled Headers
```d
pch: {
    strategy: none|auto|manual;
    header: "pch.h";
    output: "pch.h.gch";
    force: false;
}
```

### Unity Builds
```d
unity: {
    enabled: true;
    filesPerUnit: 50;
    prefix: "unity_";
}
```

### Code Coverage
```d
coverage: {
    enabled: true;
    tool: "auto"|"gcov"|"llvm-cov";
    format: "html"|"xml";
    outputDir: "coverage";
}
```

### CMake Integration
```d
cmakeGenerator: "Ninja"|"Unix Makefiles"|"Visual Studio 16 2019";
cmakeBuildType: "Debug"|"Release"|"RelWithDebInfo"|"MinSizeRel";
cmakeOptions: ["-DOPTION=VALUE"];
```

## Compiler Detection

The build system auto-detects available compilers in this order:
1. Clang (clang++/clang)
2. GCC (g++/gcc)
3. MSVC (cl.exe) - Windows only
4. Intel (icx/icpc or icc)

You can override with the `compiler` option or provide a custom compiler path.

## Build System Detection

When `buildSystem: "auto"`, the system detects:
1. CMakeLists.txt → CMake
2. Makefile → Make
3. build.ninja → Ninja
4. BUILD/WORKSPACE → Bazel
5. meson.build → Meson
6. xmake.lua → Xmake

Falls back to direct compiler invocation if none found.

## Header Dependency Analysis

The system automatically:
- Scans `#include` directives
- Resolves header paths from include directories
- Builds transitive dependency graphs
- Detects template definitions requiring header-only compilation
- Suggests precompiled headers for frequently included files

## Optimization Strategies

### Precompiled Headers
The system can automatically suggest headers for precompilation:
- Analyzes header usage across all sources
- Identifies frequently included headers (>30% of files)
- Estimates compilation time benefit
- Generates optimal PCH configuration

### Unity Builds
Combine multiple source files into single translation units:
- Reduces overall compilation time
- Improves optimization opportunities
- Configurable files per unity file
- Automatic generation of unity files

### Link-Time Optimization
- **Thin LTO**: Fast, parallel LTO with good optimization
- **Full LTO**: Maximum optimization, longer link time

## Static Analysis Integration

### Clang-Tidy
Runs comprehensive checks:
- bugprone-*: Bug-prone code patterns
- cert-*: CERT secure coding standards
- clang-analyzer-*: Clang static analyzer
- cppcoreguidelines-*: C++ Core Guidelines
- modernize-*: Modern C++ practices
- performance-*: Performance improvements
- readability-*: Code readability

### CppCheck
Additional static analysis with focus on:
- Error detection
- Memory leaks
- Undefined behavior
- Style issues

## Sanitizer Support

All sanitizers are automatically configured with optimal options:
- **ASan**: Detects memory errors, leaks, buffer overflows
- **TSan**: Detects data races in multi-threaded code
- **MSan**: Detects uninitialized memory reads
- **UBSan**: Detects undefined behavior
- **LSan**: Dedicated leak detection
- **HWASan**: Hardware-assisted address sanitizer

## Code Coverage

Supports multiple coverage tools:
- **gcov**: GCC coverage tool
- **llvm-cov**: LLVM coverage tool
- **lcov**: HTML coverage report generator

Automatic report generation in HTML or XML format.

## Platform Support

- **Linux**: Full support (GCC, Clang)
- **macOS**: Full support (Clang, GCC via Homebrew)
- **Windows**: MSVC, Clang, GCC (MinGW/MSYS2)

## Examples

See `examples/cpp-project/` for a working example.

## Performance Characteristics

### Compilation Speed
- Direct compilation: Fastest for simple projects
- CMake: Best for complex projects with caching
- Unity builds: 2-5x faster for large projects
- PCH: 1.5-3x faster when many headers shared

### Optimization Levels
- O0: No optimization, fastest compile, largest binaries
- O1: Basic optimization, reasonable compile time
- O2: Good optimization, standard for most projects
- O3: Aggressive optimization, longer compile time
- Os: Size optimization
- Ofast: Fastest runtime, may break standards compliance

### LTO Impact
- Thin LTO: 5-20% runtime improvement, moderate link time
- Full LTO: 10-30% runtime improvement, significant link time

## Future Enhancements

- **Package Manager Integration**: Conan, vcpkg, Hunter
- **Additional Build Systems**: Bazel, Meson, Xmake
- **Module Support**: Full C++20 module compilation
- **Distributed Compilation**: ccache, distcc, icecc
- **Advanced Analysis**: Include-what-you-use, cppclean
- **Profile-Guided Optimization**: PGO support
- **Binary Analysis**: Binary size optimization

## Best Practices

1. **Use C++17 or later** for modern features and better optimization
2. **Enable warnings** (`warnings: "all"` or `"error"`)
3. **Use LTO for release builds** to maximize performance
4. **Enable sanitizers in debug builds** to catch bugs early
5. **Use static analysis** (`analyzer: "clang-tidy"`) regularly
6. **Format code consistently** (`format: true`)
7. **Enable compile_commands.json** for IDE integration
8. **Use PCH for large projects** with many shared headers
9. **Consider unity builds** for faster compilation
10. **Profile before optimizing** - use `timeReport: true`

## Troubleshooting

### Compiler Not Found
- Ensure compiler is installed and in PATH
- Use `customCompiler` to specify exact path
- Check compiler version compatibility

### Build System Not Found
- Install required build system (cmake, make, ninja)
- Fallback to `buildSystem: "none"` for direct compilation

### Header Not Found
- Add include directories with `includeDirs`
- Check for missing dependencies
- Verify header paths are correct

### Link Errors
- Add missing libraries with `libs`
- Add library directories with `libDirs`
- Check library compatibility (static vs shared)

### Sanitizer Issues
- Sanitizers may conflict (don't use TSan with ASan/MSan)
- Requires recent compiler version
- May need to recompile dependencies with sanitizers

