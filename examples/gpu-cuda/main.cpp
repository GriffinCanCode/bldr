#include <cuda_runtime.h>
#include <iostream>
#include <vector>

// Declarations from CUDA kernels
extern "C" {
    void launch_vector_add(const float* a, const float* b, float* c, int n);
    void launch_matmul(const float* A, const float* B, float* C, int M, int N, int K);
}

int main() {
    // Simple vector addition test
    const int N = 1024;
    std::vector<float> h_a(N, 1.0f);
    std::vector<float> h_b(N, 2.0f);
    std::vector<float> h_c(N);
    
    float *d_a, *d_b, *d_c;
    cudaMalloc(&d_a, N * sizeof(float));
    cudaMalloc(&d_b, N * sizeof(float));
    cudaMalloc(&d_c, N * sizeof(float));
    
    cudaMemcpy(d_a, h_a.data(), N * sizeof(float), cudaMemcpyHostToDevice);
    cudaMemcpy(d_b, h_b.data(), N * sizeof(float), cudaMemcpyHostToDevice);
    
    launch_vector_add(d_a, d_b, d_c, N);
    
    cudaMemcpy(h_c.data(), d_c, N * sizeof(float), cudaMemcpyDeviceToHost);
    
    // Verify
    bool pass = true;
    for (int i = 0; i < N; i++) {
        if (h_c[i] != 3.0f) {
            pass = false;
            break;
        }
    }
    
    std::cout << "Vector addition: " << (pass ? "PASS" : "FAIL") << std::endl;
    
    cudaFree(d_a);
    cudaFree(d_b);
    cudaFree(d_c);
    
    return pass ? 0 : 1;
}

