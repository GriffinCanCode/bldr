# CUDA GPU Kernel Example

Example CUDA kernels for ML/compute workloads.

## Prerequisites

- NVIDIA GPU with compute capability 8.0+ (RTX 30xx/40xx, A100, H100)
- CUDA Toolkit 11.x or 12.x
- Verify with: `nvcc --version`

## Build

```bash
cd examples/gpu-cuda
bldr build ml_kernels    # Just the library
bldr build cuda_app      # Full application
```

## Kernels Included

### vector_ops.cu
- `vector_add` - Element-wise vector addition
- `vector_scale` - Scale vector by scalar
- `dot_product` - Dot product with shared memory reduction

### matrix_ops.cu
- `matmul` - Basic matrix multiplication
- `matmul_tiled` - Tiled matmul with shared memory (faster)
- `relu` - ReLU activation
- `softmax` - Row-wise softmax

## Multi-Architecture Build

The example builds for sm_80 (Ampere) and sm_90 (Hopper). Modify `arch` in Builderfile for your GPU:

```d
cuda: {
    arch: ["sm_75"];  // RTX 20xx (Turing)
}
```

Common architectures:
- `sm_70` - Volta (V100)
- `sm_75` - Turing (RTX 20xx)
- `sm_80` - Ampere (RTX 30xx, A100)
- `sm_86` - Ampere GA102 (RTX 3090)
- `sm_89` - Ada (RTX 40xx)
- `sm_90` - Hopper (H100)

