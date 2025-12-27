#include <cuda_runtime.h>

// Matrix multiplication: C = A * B
// A is MxK, B is KxN, C is MxN
__global__ void matmul(const float* A, const float* B, float* C, int M, int N, int K) {
    int row = blockIdx.y * blockDim.y + threadIdx.y;
    int col = blockIdx.x * blockDim.x + threadIdx.x;
    
    if (row < M && col < N) {
        float sum = 0.0f;
        for (int k = 0; k < K; k++) {
            sum += A[row * K + k] * B[k * N + col];
        }
        C[row * N + col] = sum;
    }
}

// Tiled matrix multiplication with shared memory
#define TILE_SIZE 16

__global__ void matmul_tiled(const float* A, const float* B, float* C, int M, int N, int K) {
    __shared__ float As[TILE_SIZE][TILE_SIZE];
    __shared__ float Bs[TILE_SIZE][TILE_SIZE];
    
    int row = blockIdx.y * TILE_SIZE + threadIdx.y;
    int col = blockIdx.x * TILE_SIZE + threadIdx.x;
    
    float sum = 0.0f;
    
    for (int t = 0; t < (K + TILE_SIZE - 1) / TILE_SIZE; t++) {
        // Load tiles
        if (row < M && t * TILE_SIZE + threadIdx.x < K)
            As[threadIdx.y][threadIdx.x] = A[row * K + t * TILE_SIZE + threadIdx.x];
        else
            As[threadIdx.y][threadIdx.x] = 0.0f;
            
        if (col < N && t * TILE_SIZE + threadIdx.y < K)
            Bs[threadIdx.y][threadIdx.x] = B[(t * TILE_SIZE + threadIdx.y) * N + col];
        else
            Bs[threadIdx.y][threadIdx.x] = 0.0f;
            
        __syncthreads();
        
        // Compute
        for (int k = 0; k < TILE_SIZE; k++) {
            sum += As[threadIdx.y][k] * Bs[k][threadIdx.x];
        }
        
        __syncthreads();
    }
    
    if (row < M && col < N) {
        C[row * N + col] = sum;
    }
}

// ReLU activation
__global__ void relu(const float* input, float* output, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        output[idx] = fmaxf(0.0f, input[idx]);
    }
}

// Softmax (row-wise for batched)
__global__ void softmax(const float* input, float* output, int rows, int cols) {
    int row = blockIdx.x;
    if (row >= rows) return;
    
    // Find max for numerical stability
    float maxVal = input[row * cols];
    for (int i = 1; i < cols; i++) {
        maxVal = fmaxf(maxVal, input[row * cols + i]);
    }
    
    // Compute exp and sum
    float sum = 0.0f;
    for (int i = 0; i < cols; i++) {
        float e = expf(input[row * cols + i] - maxVal);
        output[row * cols + i] = e;
        sum += e;
    }
    
    // Normalize
    for (int i = 0; i < cols; i++) {
        output[row * cols + i] /= sum;
    }
}

// Wrapper functions
extern "C" {
    void launch_matmul(const float* A, const float* B, float* C, int M, int N, int K) {
        dim3 blockSize(16, 16);
        dim3 numBlocks((N + 15) / 16, (M + 15) / 16);
        matmul_tiled<<<numBlocks, blockSize>>>(A, B, C, M, N, K);
    }
    
    void launch_relu(const float* input, float* output, int n) {
        int blockSize = 256;
        int numBlocks = (n + blockSize - 1) / blockSize;
        relu<<<numBlocks, blockSize>>>(input, output, n);
    }
}

