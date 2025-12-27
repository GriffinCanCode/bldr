module languages.gpu.rocm;

/// ROCm/HIP Language Support
/// 
/// Provides compilation support for AMD ROCm GPU kernels using hipcc.
/// 
/// Features:
///   - HIP compiler (hipcc) integration
///   - AMD GPU architecture targets (gfx900, gfx906, gfx908, gfx90a, gfx1030, etc.)
///   - Dependency tracking
///   - CUDA code portability via HIP
///
/// Usage in Builderfile:
///   target("rocm_kernel") {
///       type: library;
///       language: rocm;
///       sources: ["src/*.hip"];
///       rocm: {
///           arch: ["gfx908", "gfx90a"];
///           debug: false;
///       }
///   }

public import languages.gpu.rocm.core;
