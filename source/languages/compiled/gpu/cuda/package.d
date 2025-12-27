module languages.compiled.gpu.cuda;

/// CUDA Language Support
/// 
/// Provides compilation support for NVIDIA CUDA GPU kernels using nvcc.
/// 
/// Features:
///   - Dependency tracking via nvcc -M -MF
///   - Multi-architecture compilation (sm_70, sm_80, sm_90, etc.)
///   - PTX/SASS caching
///   - Integration with host C++ code
///   - Device-link support for separate compilation
///   - cuBLAS, cuDNN library integration
///
/// Usage in Builderfile:
///   target("cuda_kernel") {
///       type: library;
///       language: cuda;
///       sources: ["src/*.cu"];
///       cuda: {
///           arch: ["sm_80", "sm_90"];
///           debug: false;
///           relocatable: true;
///       }
///   }

public import languages.compiled.gpu.cuda.core;
public import languages.compiled.gpu.cuda.builders;

