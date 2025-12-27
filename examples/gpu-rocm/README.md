# ROCm/HIP GPU Kernel Example

Example HIP kernels for AMD GPUs. HIP code is portable - can also compile on NVIDIA GPUs.

## Prerequisites

- AMD GPU with ROCm support (Vega, RDNA2/3, CDNA/CDNA2/CDNA3)
- ROCm 5.x or 6.x
- Verify with: `hipcc --version`

## Build

```bash
cd examples/gpu-rocm
bldr build hip_kernels
```

## Kernels Included

### vector_ops.hip
- `vector_add` - Element-wise vector addition
- `vector_scale` - Scale vector by scalar
- `dot_product` - Dot product with shared memory reduction

### matrix_ops.hip
- `matmul_tiled` - Tiled matmul with shared memory
- `relu` - ReLU activation

## Supported Architectures

Modify `arch` in Builderfile for your GPU:

```d
rocm: {
    arch: ["gfx1030"];  // RX 6000 series
}
```

Common architectures:
- `gfx900` - Vega 10 (RX Vega 56/64)
- `gfx906` - Vega 20 (Radeon VII)
- `gfx908` - CDNA (MI100)
- `gfx90a` - CDNA2 (MI200 series)
- `gfx1030` - RDNA2 (RX 6800/6900)
- `gfx1100` - RDNA3 (RX 7900)
- `gfx940/942` - CDNA3 (MI300)

## CUDA Portability

HIP code can compile on NVIDIA GPUs too:

```bash
# With nvcc backend
export HIP_PLATFORM=nvidia
hipcc src/vector_ops.hip -o vector_ops
```

