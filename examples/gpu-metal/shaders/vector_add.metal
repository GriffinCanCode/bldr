#include <metal_stdlib>
using namespace metal;

/// Simple vector addition kernel
kernel void vector_add(
    device const float* inA [[buffer(0)]],
    device const float* inB [[buffer(1)]],
    device float* result [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    result[id] = inA[id] + inB[id];
}

/// Vector scale kernel
kernel void vector_scale(
    device const float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    constant float& scalar [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    output[id] = input[id] * scalar;
}

/// Dot product reduction (partial)
kernel void dot_product_partial(
    device const float* vecA [[buffer(0)]],
    device const float* vecB [[buffer(1)]],
    device float* partialSums [[buffer(2)]],
    uint id [[thread_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]],
    uint blockDim [[threads_per_threadgroup]]
) {
    threadgroup float sharedMem[256];
    
    sharedMem[tid] = vecA[id] * vecB[id];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // Reduction in shared memory
    for (uint s = blockDim / 2; s > 0; s >>= 1) {
        if (tid < s) {
            sharedMem[tid] += sharedMem[tid + s];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    
    if (tid == 0) {
        partialSums[id / blockDim] = sharedMem[0];
    }
}

