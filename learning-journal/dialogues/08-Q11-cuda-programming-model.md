# Q11 — CUDA 编程模型最小子集（Day 11）

> **目标**：用 vLLM 真实 kernel `silu_and_mul` 把 grid/block/thread/warp/SMEM/同步打通。
> 学完之后，你能读懂 `csrc/*.cu`，能用 `cuda-gdb` 单步任何 kernel，能在简历上说"会写 CUDA kernel"。

---

## 1. Scenario（场景）

vLLM 的 MLP 层（每个 transformer block 都有）大致这样：

```
hidden = x @ W_gate_up        # [num_tokens, 2d]   ←— 一次大 GEMM
hidden = silu_and_mul(hidden) # [num_tokens, d]    ←— 我们今天讲的 kernel
out    = hidden @ W_down      # [num_tokens, h]
```

`silu_and_mul` 干的事极简单：

```python
gate, up = hidden.chunk(2, dim=-1)   # 各 [num_tokens, d]
return silu(gate) * up               # element-wise
```

PyTorch 写一行就完了。**为什么 vLLM 要手写 CUDA？**
答：PyTorch 这一行会 launch 3 个 kernel（chunk view、silu、mul），中间结果走 HBM 来回跑两次。
手写一个融合 kernel：从 HBM 读 1 次、写 1 次，省 2/3 的内存带宽。
**这就是 LLM kernel 工程师的全部工作**——融合 + 减少 HBM 访问。

源码：[`csrc/activation_kernels.cu`](file:///home/xuefeiz2/3rd/vllm/csrc/activation_kernels.cu#L78-L130)

---

## 2. Intuition（直觉）

把 GPU 想象成一个**纺织厂**：

| 概念 | 工厂类比 | 数量级（RTX PRO 6000 Blackwell） |
|---|---|---|
| **Thread**（线程） | 一个工人 | 同时几百万个 |
| **Warp**（束） | 32 人一组、必须同步动作的小队 | 硬件最小调度单位 |
| **Block**（块） | 一个车间，最多 1024 工人，共享一块小桌子（SMEM） | 同步只能在车间内 |
| **Grid**（网格） | 整个工厂下达的一次任务，包含很多车间 | 一次 kernel launch = 一个 grid |
| **SM**（Streaming Multiprocessor） | 物理车间楼，每栋同时容纳几个车间 | sm_120 大约 170 个 SM |
| **SMEM**（共享内存） | 车间内的小桌子，约 100 KB，纳秒级 | 同 block 内共享 |
| **HBM**（global memory） | 工厂外的中央仓库，96 GB，几百纳秒 | 所有 grid 共享 |

**核心规则**：
1. 你写 kernel 时，是站在**单个工人（thread）**的视角描述 "我要干什么"。
2. CUDA runtime 帮你复制几百万份这段代码同时跑。
3. 工人通过 `threadIdx`、`blockIdx` 知道"我是谁、该处理哪份数据"。

---

## 3. System Principle（系统原理：从 OS/并行计算视角）

### 3.1 SIMT vs SIMD vs MIMD

| 模型 | 例子 | 一条指令影响 | 分支怎么办 |
|---|---|---|---|
| MIMD | 多核 CPU | 1 个核 | 各跑各的 |
| SIMD | AVX-512 | 8/16 个 lane | 必须显式 mask |
| **SIMT** | NVIDIA GPU | 一个 warp = 32 个 thread | 硬件自动 mask（warp divergence 性能下降） |

**SIMT = "一个 PC、32 套寄存器"**：warp 里 32 个 thread **共享一个 program counter**，但每人有自己的 register 和数据。
所以同一时刻 32 个 thread **必须**执行同一条指令（或者被 mask 掉）。

### 3.2 内存层次复习（Q9 已讲，这里加上 latency 数字）

| 层 | 位置 | 容量 | 延迟 | 写者视角 |
|---|---|---|---|---|
| Register | 每 thread 私有 | 256 个 32-bit/thread | 0 cycle | 编译器决定 |
| **SMEM / L1** | block 共享 | ~100 KB/SM | ~30 cycle | `__shared__` 关键字 |
| L2 cache | grid 共享 | ~50-100 MB | ~200 cycle | 硬件管理 |
| **HBM** | grid 共享 | 96 GB | ~400-800 cycle | 普通 pointer |

**这就是为什么写 CUDA 的核心思路是**：尽量在 SMEM/Register 干活，HBM 只读写一次。FlashAttention 整个故事就是把 attention 从"反复扫 HBM"变成"在 SMEM 里 tile-by-tile"。

### 3.3 同步原语：和 pthread 的对比

| 你熟悉的 pthread | CUDA 对应 | 作用范围 |
|---|---|---|
| 无锁/原子 | `atomicAdd`, `atomicCAS` | 全局 |
| `pthread_barrier` | `__syncthreads()` | **仅同 block 内** |
| 全局同步 | **没有！** kernel 结束 = 全局同步点 | grid-level |
| `pthread_mutex` | 有但极少用（性能差） | 全局 |

**重点**：
- block 之间**不能**同步（除非用 cooperative groups + 特殊 launch，绝大多数 kernel 不用）。
- 所以"全局同步"的标准做法是：**结束当前 kernel，再 launch 下一个 kernel**。kernel launch 之间隐式同步。
- warp 内部 32 个 thread **天然 lock-step**（在 sm_70 之前），sm_70 之后需要 `__syncwarp()` 显式同步。

### 3.4 和 Linux 进程模型的类比

| Linux | CUDA |
|---|---|
| 进程 (`fork`) | grid（一次 kernel launch） |
| 线程 (`pthread_create`) | block 里的 thread |
| 进程间通信 (pipe/shm) | 跨 grid：必须经过 HBM + 新 launch |
| 线程间通信 (共享地址空间 + mutex) | 同 block：SMEM + `__syncthreads()` |
| context switch | warp scheduler 0 cycle 切换（GPU 用海量并发掩盖延迟） |

最后一行是 GPU 设计哲学的核心：**CPU 用 cache 降延迟，GPU 用并发掩盖延迟**。
SM 上同时驻留几十个 warp，一个 warp 等 HBM 时，scheduler 立刻切到另一个 ready warp，0 开销。所以**让 SM 上有足够多的 warp**（occupancy）比"让单个 warp 跑得快"更重要。

---

## 4. vLLM Source（源码精读）

打开 [`csrc/activation_kernels.cu`](file:///home/xuefeiz2/3rd/vllm/csrc/activation_kernels.cu)，看 `silu_and_mul` 的最简版本（line 113-128）：

```cpp
template <typename scalar_t, scalar_t (*ACT_FN)(const scalar_t&), bool act_first>
__global__ void act_and_mul_kernel_no_vec(
    scalar_t* __restrict__ out,          // [num_tokens, d]
    const scalar_t* __restrict__ input,  // [num_tokens, 2*d]
    const int d) {
  const int64_t token_idx = blockIdx.x;            // 我是哪个 token？
  for (int64_t idx = threadIdx.x; idx < d; idx += blockDim.x) {
    // 我处理 hidden dim 的第 idx 维（步长 = blockDim.x）
    const scalar_t x = input[token_idx * 2 * d + idx];
    const scalar_t y = input[token_idx * 2 * d + d + idx];
    out[token_idx * d + idx] = compute<scalar_t, ACT_FN, act_first, false>(x, y, 0.0f);
  }
}
```

**逐行解读**：

1. `__global__`：表示这是一个 kernel（host 调用、device 执行）。对比：
   - `__device__`：device 调用、device 执行（普通函数）。
   - `__host__`：host 调用、host 执行（普通 CPU 函数）。
   - `__device__ __host__`：两边都能编（数学小工具常用）。

2. `__restrict__`：和 C99 一样，承诺这两个指针不重叠，让编译器更激进地优化。

3. `blockIdx.x`：本 block 在 grid 里的编号（0..num_tokens-1）。
   `threadIdx.x`：本 thread 在 block 里的编号（0..blockDim.x-1）。

4. **数据并行模式**：`grid = num_tokens` 个 block，**每个 block 处理一个 token**；
   一个 block 里有 `blockDim.x`（最多 1024）个 thread，**每个 thread 处理 hidden dim 的一部分**。

5. `for (idx = threadIdx.x; idx < d; idx += blockDim.x)`：经典的 **grid-stride loop**（这里是 block-stride）。当 `d > blockDim.x` 时，每个 thread 处理多个元素，步长 = `blockDim.x`。
   - **为什么不直接 `idx = threadIdx.x` 一次**？因为 `d` 可能是 11008（Llama 7B 中间层），而 `blockDim.x` 最多 1024。
   - **为什么步长是 `blockDim.x` 而不是 1**？因为这样**相邻 thread 访问相邻地址**（thread 0 访问 idx=0, thread 1 访问 idx=1, ...），HBM 把这 32 个访问合并成 1 个 cache line 读 = **memory coalescing**。是 GPU 性能第一定律。

### 4.1 Launch 配置（line 204-253）

```cpp
dim3 grid(num_tokens);                       // 一个 block / token
dim3 block(std::min(d, 1024));               // 线程数 = min(hidden_dim, 1024)
kernel<<<grid, block, 0, stream>>>(...);     // <<<grid, block, smem_bytes, stream>>>
```

`<<<...>>>` 这个三尖括号语法是 **CUDA 对 C++ 的扩展**，nvcc 会把它翻成一个 runtime 调用（`cudaLaunchKernel`）。
- 第三个参数 `0` = 动态 SMEM 字节数（这个 kernel 不用 SMEM）。
- 第四个参数 `stream` = CUDA stream（异步队列，类似 OS 的 work queue）。

### 4.2 完整调用链（PyTorch → C++ → CUDA）

```
Python:  torch.ops._C.silu_and_mul(out, input)
         │
         ▼  (PyTorch dispatcher)
C++:     csrc/torch_bindings.cpp 注册的 silu_and_mul()
         │
         ▼
C++:     csrc/activation_kernels.cu :: silu_and_mul()  (line 255)
         │   LAUNCH_ACTIVATION_GATE_KERNEL 宏
         ▼
CUDA:    act_and_mul_kernel<<<grid, block>>>(...)
         │
         ▼  (硬件)
SM:      170 个 SM 同时跑很多 block
```

### 4.3 vLLM 里 CUDA kernel 的几大类（你将来可能改的）

| 文件 | 功能 | 难度 |
|---|---|---|
| `csrc/activation_kernels.cu` | SiLU/GeLU + mul 融合 | ★ |
| `csrc/layernorm_kernels.cu` | RMSNorm/LayerNorm | ★★ |
| `csrc/pos_encoding_kernels.cu` | RoPE 旋转位置编码 | ★★ |
| `csrc/cache_kernels.cu` | KV cache reshape/copy（PagedAttention 配套） | ★★★ |
| `csrc/attention/paged_attention_v1.cu` | PagedAttention 朴素版 | ★★★★ |
| FA / FlashInfer（外部库） | FlashAttention | ★★★★★ |

---

## 5. Hands-on（动手，~30 min）

### 实验 A：用 cuda-gdb 单步 silu_and_mul（10 min）

```bash
source .venv/bin/activate
cat > /tmp/silu_test.py <<'EOF'
import torch
from vllm import _custom_ops as ops
x = torch.randn(2, 8, dtype=torch.float16, device="cuda") * 2  # [num_tokens=2, 2d=8]
out = torch.empty(2, 4, dtype=torch.float16, device="cuda")
ops.silu_and_mul(out, x)
print("input:", x); print("output:", out)
EOF

# 启动 cuda-gdb（需要 debug build）
cuda-gdb --args .venv/bin/python /tmp/silu_test.py
```

在 cuda-gdb 里：

```
(cuda-gdb) break activation_kernels.cu:118
(cuda-gdb) run
... (会停在 kernel 入口，但是是某个 thread 视角)
(cuda-gdb) info cuda threads     # 查看所有 active thread
(cuda-gdb) cuda thread (0,0,0)   # 切到 (block=0, thread=0)
(cuda-gdb) print token_idx       # = 0
(cuda-gdb) print threadIdx.x     # = 0
(cuda-gdb) cuda thread (1,2,0)   # 切到 (block=1, thread=2)
(cuda-gdb) print token_idx       # = 1
(cuda-gdb) print idx             # = 2
```

**观察点**：你能在 GPU 上像 gdb 一样切线程视角。**这就是 debug build 的全部价值。**

### 实验 B：手写一个 vector_add（15 min）

写在 `learning-journal/code-experiments/05_vector_add.cu`，亲手感受 grid/block 划分。我已经写好了（见下一节），你只需要：

```bash
cd learning-journal/code-experiments/
nvcc -arch=sm_120 -lineinfo -g 05_vector_add.cu -o 05_vector_add
./05_vector_add
```

输出应类似：
```
N=1048576, block=256, grid=4096
result correct
elapsed: 0.12 ms, bandwidth: 70 GB/s
```

修改 `block_size` 试试 32/128/256/512/1024，观察带宽变化。**32 太小（warp 调度不充分），1024 也未必最快（occupancy 降低）。一般 128/256 是 sweet spot。**

### 实验 C：用 nsys 看 silu_and_mul（5 min）

```bash
source scripts/runtime-trace.env
nsys profile -o /tmp/silu --force-overwrite=true .venv/bin/python /tmp/silu_test.py
nsys stats /tmp/silu.nsys-rep | head -40
```

找到 `act_and_mul_kernel` 这一行，看它的 grid/block size、duration、占总时间百分比。

---

## 6. Interview Script（面试话术）

**短版本（30s，"讲一下 CUDA 编程模型"）**：

> CUDA 是 SIMT 模型，一次 launch 就是一个 grid，grid 由 block 组成、block 由 thread 组成；32 个 thread 是一个 warp，是硬件最小调度单位。block 内可以通过 SMEM 和 `__syncthreads()` 通信，block 之间只能通过结束 kernel + 启新 kernel 来同步。写 kernel 的核心是 memory coalescing 和让 SM 有足够 occupancy。

**长版本（2 min，"以 vLLM 的 silu_and_mul 为例"）**：

> vLLM 的 MLP 里 `silu_and_mul` 把 SiLU 激活和逐元素乘法融合成一个 kernel，避免中间结果写回 HBM——这是 LLM kernel 优化的典型套路。它的 launch 配置是 `grid=num_tokens, block=min(d, 1024)`，每个 block 处理一个 token，block 内的 thread 用 grid-stride loop 处理 hidden dim。`for (i = threadIdx.x; i < d; i += blockDim.x)` 这个写法保证相邻 thread 访问相邻地址，触发 memory coalescing。我用 cuda-gdb 单步过这个 kernel，验证了 `blockIdx.x = token_idx`、`threadIdx.x = 起始 hidden dim 偏移`。
>
> 这个 kernel 不用 SMEM，因为是纯 element-wise；如果是 RMSNorm 就要用 SMEM 做 block-level reduction。再复杂一层就是 PagedAttention 和 FlashAttention，要用 SMEM tile 做 online softmax。

**追问预判**：

| 追问 | 答 |
|---|---|
| warp 是什么？为什么是 32？ | 硬件设计：32 thread 共享一个 PC + warp scheduler。Pascal 之后有 ITS，但调度粒度仍是 32。 |
| memory coalescing 失败会怎样？ | 一个 warp 32 次 HBM 访问，理论带宽降到 1/32。 |
| occupancy 是什么？为什么重要？ | SM 上同时驻留的 warp 数 / 硬件最大值。高 occupancy 让 warp scheduler 总有 ready warp 来掩盖 HBM 延迟。 |
| `__syncthreads()` 和 `__syncwarp()` 区别？ | 前者整个 block barrier，后者只 32 thread。Volta 后 warp 不再天然 lock-step，需要显式 syncwarp。 |
| block 之间怎么通信？ | 严格说不能。要么走 atomicAdd 到 HBM（慢），要么结束 kernel 再 launch 一个。cooperative groups 是例外但很少用。 |
| 为什么 GPU 比 CPU 适合 LLM？ | LLM 是数据并行 + 高算术强度（attention 除外）；GPU 用海量并发掩盖 HBM 延迟，CPU 受限于 cache 容量。 |
| 你写过 CUDA kernel 吗？ | 写过 vector_add 验证 grid/block，trace 过 vLLM 的 silu_and_mul 和 paged_attention_v1，正在读 FlashAttention。（**说实话，narrow + deep**） |

---

## 认知校准（学完后该有的状态）

- [ ] 看到 `<<<grid, block>>>` 不再害怕，能算出总 thread 数 = grid.x * block.x（如果是 1D）。
- [ ] 知道 `blockIdx`、`threadIdx`、`blockDim`、`gridDim` 这 4 个内置变量。
- [ ] 理解 grid-stride loop 为什么这么写，能解释 memory coalescing。
- [ ] 知道 SMEM、`__syncthreads()` 的作用范围（block 内）。
- [ ] 能在 cuda-gdb 里切 thread、看寄存器。
- [ ] 看到 `__global__ / __device__ / __host__` 不混乱。
- [ ] 听到 occupancy、warp divergence、bank conflict 这三个词知道大致是什么（细节后面学 FA-3 时再补）。

---

## 下一步

- Day 12：读 `csrc/layernorm_kernels.cu`，理解 block-level reduction（用 SMEM）。
- Day 13：Q12 — Tensor Parallel + NCCL。
