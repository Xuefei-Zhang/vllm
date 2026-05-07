// 05_vector_add.cu — Day 11 配套实验
// 编译：nvcc -arch=sm_120 -lineinfo -g 05_vector_add.cu -o 05_vector_add
// 运行：./05_vector_add
//
// 目的：亲手感受 grid/block 划分 + memory coalescing + 计时。

#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>

#define CUDA_CHECK(x)                                                          \
  do {                                                                         \
    cudaError_t err = (x);                                                     \
    if (err != cudaSuccess) {                                                  \
      fprintf(stderr, "CUDA error %s at %s:%d\n",                              \
              cudaGetErrorString(err), __FILE__, __LINE__);                    \
      exit(1);                                                                 \
    }                                                                          \
  } while (0)

// 经典 grid-stride loop 写法。
// - 每个 thread 处理 idx, idx + total_threads, idx + 2*total_threads, ...
// - 相邻 thread 访问相邻地址 → memory coalescing
__global__ void vector_add(const float* __restrict__ a,
                           const float* __restrict__ b,
                           float* __restrict__ c,
                           int n) {
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  int stride = blockDim.x * gridDim.x;
  for (int i = idx; i < n; i += stride) {
    c[i] = a[i] + b[i];
  }
}

int main(int argc, char** argv) {
  int n = 1 << 20;                 // 1M elements
  int block_size = 256;            // 改这里试 32/128/256/512/1024
  if (argc >= 2) block_size = atoi(argv[1]);

  // grid 大小：覆盖所有元素，向上取整
  int grid_size = (n + block_size - 1) / block_size;
  printf("N=%d, block=%d, grid=%d\n", n, block_size, grid_size);

  // host 分配 + 初始化
  float *h_a = (float*)malloc(n * sizeof(float));
  float *h_b = (float*)malloc(n * sizeof(float));
  float *h_c = (float*)malloc(n * sizeof(float));
  for (int i = 0; i < n; i++) { h_a[i] = i * 0.001f; h_b[i] = i * 0.002f; }

  // device 分配 + 拷贝
  float *d_a, *d_b, *d_c;
  CUDA_CHECK(cudaMalloc(&d_a, n * sizeof(float)));
  CUDA_CHECK(cudaMalloc(&d_b, n * sizeof(float)));
  CUDA_CHECK(cudaMalloc(&d_c, n * sizeof(float)));
  CUDA_CHECK(cudaMemcpy(d_a, h_a, n * sizeof(float), cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(d_b, h_b, n * sizeof(float), cudaMemcpyHostToDevice));

  // 计时（CUDA event 是 GPU 端计时器，比 CPU clock 准）
  cudaEvent_t start, stop;
  cudaEventCreate(&start); cudaEventCreate(&stop);

  // warmup
  vector_add<<<grid_size, block_size>>>(d_a, d_b, d_c, n);
  CUDA_CHECK(cudaDeviceSynchronize());

  // 正式计时
  cudaEventRecord(start);
  for (int rep = 0; rep < 100; rep++) {
    vector_add<<<grid_size, block_size>>>(d_a, d_b, d_c, n);
  }
  cudaEventRecord(stop);
  cudaEventSynchronize(stop);

  float ms = 0;
  cudaEventElapsedTime(&ms, start, stop);
  ms /= 100.0f;

  // 带宽 = 读 a + 读 b + 写 c = 3 * n * sizeof(float)
  double gb = 3.0 * n * sizeof(float) / 1e9;
  double bw = gb / (ms / 1e3);
  printf("elapsed: %.3f ms, bandwidth: %.1f GB/s\n", ms, bw);

  // 验证
  CUDA_CHECK(cudaMemcpy(h_c, d_c, n * sizeof(float), cudaMemcpyDeviceToHost));
  bool ok = true;
  for (int i = 0; i < n; i++) {
    float expected = h_a[i] + h_b[i];
    if (fabsf(h_c[i] - expected) > 1e-4f) { ok = false; break; }
  }
  printf("result %s\n", ok ? "correct" : "WRONG");

  cudaFree(d_a); cudaFree(d_b); cudaFree(d_c);
  free(h_a); free(h_b); free(h_c);
  return 0;
}
