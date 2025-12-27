# GPU Compute Languages

First-class support for GPU kernel compilation with proper dependency tracking.

## Architecture

All GPU handlers extend `BaseGPUHandler` from `languages/gpu/base.d`:

```
languages/gpu/
├── base.d          ← BaseGPUHandler (shared compile/link workflow)
├── cuda/core/      ← CUDAHandler extends BaseGPUHandler
├── metal/core/     ← MetalHandler extends BaseGPUHandler
├── rocm/core/      ← ROCmHandler extends BaseGPUHandler
└── package.d
```

The base class provides:
- Device/host source file separation
- Unified compile → link workflow with caching
- Dependency tracking infrastructure
- Progress reporting and error codes
- Test execution framework

Individual handlers only implement:
- Toolkit detection (nvcc, xcrun, hipcc)
- Architecture flag generation
- Compiler/linker command building

## Supported Languages

### CUDA (NVIDIA)

Compile NVIDIA GPU kernels using nvcc.

**File Extensions:** `.cu`, `.cuh`

**Configuration:**

```d
target("cuda_kernels") {
    type: library;
    language: cuda;
    sources: ["src/*.cu"];
    cuda: {
        arch: ["sm_80", "sm_90"];
        opt: "O3";
        debug: false;
        relocatable: true;
        fastMath: true;
        libs: ["cublas", "cudnn"];
    }
}
```

**Features:**
- Multi-architecture compilation (sm_70, sm_80, sm_90, etc.)
- Dependency tracking via `nvcc -M -MF`
- PTX/SASS caching
- Device-link support for separate compilation
- Integration with cuBLAS, cuDNN libraries

### ROCm/HIP (AMD)

Compile AMD GPU kernels using hipcc.

**File Extensions:** `.hip`, `.hiph`

**Configuration:**

```d
target("rocm_kernels") {
    type: library;
    language: rocm;
    sources: ["src/*.hip"];
    rocm: {
        arch: ["gfx908", "gfx90a"];
        opt: "O3";
        debug: false;
    }
}
```

**Features:**
- AMD GPU architectures (gfx900, gfx908, gfx90a, gfx1030, etc.)
- CUDA code portability via HIP
- Dependency tracking via hipcc

### Metal (Apple)

Compile Apple Metal GPU shaders.

**File Extensions:** `.metal`, `.metallib`

**Configuration:**

```d
target("metal_shaders") {
    type: library;
    language: metal;
    sources: ["shaders/*.metal"];
    metal: {
        platform: "macos";
        version: "3.0";
        debug: false;
    }
}
```

**Features:**
- macOS, iOS, tvOS support
- Metal 1.x, 2.x, 3.x language versions
- AIR (Apple Intermediate Representation) caching
- metallib generation

## Dependency Tracking

All GPU handlers support proper dependency tracking:

1. **CUDA**: Uses `nvcc -M -MF` to generate Makefile-compatible dependency files
2. **ROCm**: Uses `hipcc -MMD -MF` for dependency generation
3. **Metal**: Parses `#include` directives for header dependencies

Dependencies are tracked in Builder's incremental compilation cache, enabling:
- Rebuild only changed kernels
- Cache PTX/AIR intermediate representations
- Action-level caching for multi-architecture builds

## Multi-Architecture Compilation

### CUDA

```d
cuda: {
    arch: ["sm_70", "sm_75", "sm_80", "sm_86", "sm_90"];
}
```

Generates fatbin with code for all specified architectures.

### ROCm

```d
rocm: {
    arch: ["gfx908", "gfx90a", "gfx1030"];
}
```

Uses `--offload-arch` for each target.

## Integration with Host Code

GPU kernels can be linked with host C++ code:

```d
target("app") {
    type: executable;
    language: cuda;
    sources: ["main.cpp", "kernels/*.cu"];
    cuda: {
        arch: ["sm_80"];
        libs: ["cudart"];
    }
}
```

## Environment Variables

### CUDA
- `CUDA_HOME` / `CUDA_PATH`: CUDA toolkit location

### ROCm
- `ROCM_PATH` / `HIP_PATH`: ROCm installation directory

## Toolchain Detection

Builder automatically detects GPU toolchains:

```bash
bldr info toolchains
```

Shows detected CUDA, ROCm, and Metal compilers with versions.

