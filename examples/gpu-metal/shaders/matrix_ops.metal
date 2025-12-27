#include <metal_stdlib>
using namespace metal;

/// Matrix multiplication kernel
/// C = A * B where A is MxK, B is KxN, C is MxN
kernel void matrix_multiply(
    device const float* A [[buffer(0)]],
    device const float* B [[buffer(1)]],
    device float* C [[buffer(2)]],
    constant uint& M [[buffer(3)]],
    constant uint& N [[buffer(4)]],
    constant uint& K [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint row = gid.y;
    uint col = gid.x;
    
    if (row >= M || col >= N) return;
    
    float sum = 0.0f;
    for (uint i = 0; i < K; i++) {
        sum += A[row * K + i] * B[i * N + col];
    }
    
    C[row * N + col] = sum;
}

/// Matrix transpose kernel
kernel void matrix_transpose(
    device const float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    constant uint& rows [[buffer(2)]],
    constant uint& cols [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint row = gid.y;
    uint col = gid.x;
    
    if (row >= rows || col >= cols) return;
    
    output[col * rows + row] = input[row * cols + col];
}

/// Element-wise ReLU activation
kernel void relu(
    device const float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    output[id] = max(0.0f, input[id]);
}

/// Softmax (simplified - assumes small vectors per thread)
kernel void softmax_row(
    device const float* input [[buffer(0)]],
    device float* output [[buffer(1)]],
    constant uint& cols [[buffer(2)]],
    uint row [[thread_position_in_grid]]
) {
    // Find max for numerical stability
    float maxVal = input[row * cols];
    for (uint i = 1; i < cols; i++) {
        maxVal = max(maxVal, input[row * cols + i]);
    }
    
    // Compute exp and sum
    float sum = 0.0f;
    for (uint i = 0; i < cols; i++) {
        float e = exp(input[row * cols + i] - maxVal);
        output[row * cols + i] = e;
        sum += e;
    }
    
    // Normalize
    for (uint i = 0; i < cols; i++) {
        output[row * cols + i] /= sum;
    }
}

