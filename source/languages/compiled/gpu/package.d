module languages.compiled.gpu;

/// GPU Compute Languages Package
/// 
/// This package contains handlers for GPU compute languages:
///   - CUDA (NVIDIA nvcc compiler)
///   - ROCm/HIP (AMD hipcc compiler)
///   - Metal (Apple metal compiler)
///
/// Features:
///   - Dependency tracking via compiler flags (-M -MF)
///   - Action-level caching for PTX/SASS/metallib outputs
///   - Multi-architecture compilation support
///   - Integration with host C++ code

public import languages.compiled.gpu.cuda;
public import languages.compiled.gpu.rocm;
public import languages.compiled.gpu.metal;

