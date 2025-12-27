#include <hip/hip_runtime.h>

// Vector addition kernel
__global__ void vector_add(const float* a, const float* b, float* c, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        c[idx] = a[idx] + b[idx];
    }
}

// Vector scale kernel  
__global__ void vector_scale(const float* input, float* output, float scalar, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        output[idx] = input[idx] * scalar;
    }
}

// Dot product with shared memory reduction
__global__ void dot_product(const float* a, const float* b, float* result, int n) {
    __shared__ float shared[256];
    
    int tid = threadIdx.x;
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    shared[tid] = (idx < n) ? a[idx] * b[idx] : 0.0f;
    __syncthreads();
    
    // Reduction
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            shared[tid] += shared[tid + s];
        }
        __syncthreads();
    }
    
    if (tid == 0) {
        atomicAdd(result, shared[0]);
    }
}

// Wrapper functions
extern "C" {
    void launch_vector_add(const float* a, const float* b, float* c, int n) {
        int blockSize = 256;
        int numBlocks = (n + blockSize - 1) / blockSize;
        hipLaunchKernelGGL(vector_add, dim3(numBlocks), dim3(blockSize), 0, 0, a, b, c, n);
    }
}

