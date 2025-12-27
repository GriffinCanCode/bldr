module languages.gpu;

/// GPU Language Support
/// 
/// Base module for GPU compute languages including CUDA, Metal, and ROCm.
/// 
/// Architecture:
///   - languages/gpu/base.d    - BaseGPUHandler shared across all GPU languages
///   - languages/gpu/cuda/     - NVIDIA CUDA support
///   - languages/gpu/metal/    - Apple Metal support
///   - languages/gpu/rocm/     - AMD ROCm/HIP support
/// 
/// Each GPU language handler extends BaseGPUHandler which provides:
///   - Unified device/host source separation
///   - Common compile/link workflow
///   - Dependency tracking and caching
///   - Architecture flag handling
///   - Test execution

public import languages.gpu.base;
public import languages.gpu.cuda;
public import languages.gpu.metal;
public import languages.gpu.rocm;

