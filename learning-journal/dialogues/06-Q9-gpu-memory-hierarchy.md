# Day 6 — Q9: GPU 内存层级 + Roofline 模型

> 你的驱动经验对应 CPU 这边的 cache 层级（L1/L2/L3/RAM）。GPU 上的层级**形似但量级和访问模式都更极端**——理解这个，所有 attention kernel 优化你都能秒懂。
>
> 阅读 ~30min / 实验 ~20min / 自测 ~10min

---

## 0. CPU 这边你应该已经熟的

```
Register   ─── 1 周期，KB 级
L1 cache   ─── 4 周期，~32 KB / core
L2 cache   ─── 12 周期，~256 KB-1MB / core
L3 cache   ─── 40 周期，几 MB-几十 MB 共享
RAM        ─── 200+ 周期，GB 级
```

驱动里你处理过 DMA、cache coherency、写合并 (write-combining) 这些。**好消息：GPU 这边的概念你都见过。**

---

## 1. GPU Memory Hierarchy（Blackwell PRO 6000）

```
                          速度 ↑       容量 ↓
┌─────────────────────────────────────────────────┐
│ Register             ~0 周期       256 KB / SM  │  ← 每 thread 私有
├─────────────────────────────────────────────────┤
│ Shared Memory (SMEM) ~30 周期      228 KB / SM  │  ← thread block 内共享
├─────────────────────────────────────────────────┤
│ L1 cache            ~30 周期      ≈ 同 SMEM     │  ← 和 SMEM 共享物理
├─────────────────────────────────────────────────┤
│ L2 cache            ~250 周期     ~128 MB 全卡  │
├─────────────────────────────────────────────────┤
│ HBM (Global Memory) ~500 周期     97 GB         │  ← 你的 KV cache 在这里
└─────────────────────────────────────────────────┘

带宽：
  Register / SMEM: ~10 TB/s （估算）
  L2:              ~5 TB/s
  HBM (HBM3e):     ~3 TB/s   ← 你 PRO 6000 的真实数字
  PCIe 5.0:        ~64 GB/s  ← CPU↔GPU 传输
```

**对比**：HBM 带宽是 PCIe 的 ~50 倍，比 CPU DDR5 (~80 GB/s) 快 ~40 倍。

---

## 2. ⭐ 关键差异：GPU 没有"自动 cache"

CPU：你写 `int x = arr[i]` → 硬件自动 prefetch、自动 cache、L1 miss 自动到 L2。**程序员什么都不用管**。

GPU 上：
- HBM → SMEM 的搬运 **要手动**（kernel 里写 `__shared__` 申请 SMEM，写 `load(global_ptr)` 显式拷贝）
- HBM → Register 的搬运 **要手动**
- L1/L2 cache 是有的，但不可控；高性能 kernel 都假设它们没用

**这就是为什么 CUDA kernel 难写**：所有数据搬运都是程序员的责任。

**驱动类比**：你写 DMA 时手动配置源地址 / 目标地址 / 长度——CUDA kernel 写起来就是无数个 DMA。

---

## 3. ⭐ Roofline 模型：判断你被什么瓶颈卡住

### 公式

```
Performance = min(
    Compute_peak,                    # 算力上限
    Memory_bandwidth × intensity     # 带宽 × 算 1 byte 的次数
)
```

`intensity = 算的次数 / 加载的 bytes` —— 算法决定的属性，硬件无关。

### 画法

```
Performance (TFLOPs)
   ↑
   │           ╭──────────────  Compute roof (~600 TFLOPs)
   │          ╱
   │         ╱
   │        ╱
   │       ╱   ← 转折点 = ridge point
   │      ╱       intensity = compute / bandwidth
   │     ╱        Blackwell ≈ 600 TF / 3 TB/s = 200 ops/byte
   │    ╱
   │   ╱  Memory roof (intensity × HBM_bw)
   │  ╱
   │ ╱
   └─────────────────→ intensity (ops/byte)
       │           │
   Memory-bound  Compute-bound
```

### LLM 推理上 4 个典型操作的 intensity

| 操作 | Intensity | 落在哪一边 |
|---|---|---|
| Decode 1 token (batch=1) | ~1 ops/byte | **极度 memory-bound** |
| Decode 1 token (batch=64) | ~64 ops/byte | **仍 memory-bound**（< 200）|
| Decode 1 token (batch=256) | ~256 ops/byte | **接近转折点** |
| Prefill 1024 token | ~1000 ops/byte | **compute-bound** |

**这就是为什么大 batch decode 才能榨出 GPU 性能** —— 把 intensity 从 1 推到 200+。

---

## 4. ⭐ Naive Attention 的灾难

教科书 attention：
```python
scores = Q @ K.T           # [N, N] 矩阵
scores = scores / sqrt(d)
weights = softmax(scores)  # [N, N]
output = weights @ V       # [N, d]
```

**问题**：中间矩阵 `[N, N]` 要写回 HBM 再读出来。

N = 4096 时，`[4096, 4096]` fp16 = **32 MB / head**。32 head → **1 GB 中间矩阵**。

```
HBM ←→ SMEM 来回搬：
  Q from HBM
  K from HBM
  scores 写回 HBM           ← 浪费！
  scores 从 HBM 读回         ← 浪费！
  weights 写回 HBM           ← 浪费！
  weights 从 HBM 读回         ← 浪费！
  V from HBM
  output 写回 HBM
```

intensity 被中间矩阵的 HBM 读写**严重稀释**——本来计算很多，但被迫成了 memory-bound。

### FlashAttention 的核心 trick（明天 Day 7 详细讲）

> **永远不把 [N, N] 矩阵写回 HBM**。在 SMEM 里 tile-by-tile 算，online 维护 softmax 的归一化项。

效果：HBM 流量从 O(N²) 降到 O(N)。intensity 从 ~10 提到 ~100。从 memory-bound 跳到接近 compute-bound。

---

## 5. KV Cache 的存储位置

vLLM 的 KV cache 物理上**在 HBM**（全局内存），按 PagedAttention 的 block 切分。

```
HBM (97 GB on PRO 6000)
├── Model weights        14 GB  (Llama-7B fp16)
├── KV cache             ~60 GB (按 gpu_memory_utilization=0.9 算)
├── Activation buffer    几 GB
└── 其余               (CUDA runtime / autograd / 临时)
```

**Decode 时的访问模式**：
1. 算第 N+1 个 token 的 attention，要从 HBM 读全部历史 K, V
2. 假设上下文 4K token，单层 KV ≈ 16 KB（fp16, 32 head, head_dim=128）
3. × 32 层 = 512 KB / 用户 / step
4. 100 用户并发 = 50 MB / step 从 HBM 读

50 MB / 3 TB/s = ~17 µs —— 听起来很短，但**每 step 都要重读，因为 SMEM 装不下**。

> KV cache 注定 memory-bound，FlashAttention 也救不了——它只优化中间矩阵 `[N, N]`，KV 本身的读取省不了。

---

## 6. Tensor Core：另一个层级

Blackwell 的 SM 里有专门的 **Tensor Core**——做小矩阵乘法（如 16×16）的硬件单元。

| 操作 | 在哪个单元跑 | 速度 |
|---|---|---|
| 标量加法 | CUDA core | 1 ops/clock |
| 向量乘加 | CUDA core (FMA) | 1 ops/clock |
| 16×16×16 矩阵乘 | **Tensor Core** | ~1000 ops/clock |

**结论**：所有 LLM 推理的 GEMM 都该跑在 Tensor Core 上。FlashAttention、cuBLAS、Triton 都自动用。

**FP precision 也是个层级**：
- fp32 (Tensor Core ~150 TFLOPs)
- fp16/bf16 (~600 TFLOPs)
- fp8 (~1200 TFLOPs)
- fp4 (~2400 TFLOPs，Blackwell 新增)

低精度 = 更高吞吐 + 更小 KV cache + 但精度损失。这就是量化的意义。

---

## 7. ncu / nsys: 实测工具

CUDA 这边的"perf top" 是 NVIDIA Nsight 套件。

### nsys (Nsight Systems): 时间线视角

```bash
nsys profile -o trace --trace=cuda,nvtx \
  .venv/bin/python your_script.py

nsys-ui trace.nsys-rep   # 用 GUI 打开
```

看到的：CUDA kernel 时间线、kernel 间的 idle gap、CPU↔GPU 同步点。

### ncu (Nsight Compute): 单 kernel 深挖

```bash
ncu --set full -o report \
  .venv/bin/python your_script.py

ncu-ui report.ncu-rep
```

**关键指标**：
- **Achieved Occupancy** —— SM 利用率
- **Memory Throughput** —— HBM 带宽利用率（接近 3 TB/s 说明 memory-bound）
- **SM Throughput** —— compute 利用率
- **Roofline analysis** —— ncu 自动画 roofline 标你的 kernel 在哪

---

## 8. 🔬 动手实验

### 实验 6-A：测你 PRO 6000 的真实带宽

```python
# 文件：learning-journal/code-experiments/06_bandwidth_test.py
import torch
import time

torch.cuda.synchronize()
N = 1024 * 1024 * 1024  # 1G fp32 = 4 GB
a = torch.randn(N, device='cuda', dtype=torch.float32)
b = torch.empty_like(a)

# Warmup
for _ in range(3):
    b.copy_(a)
torch.cuda.synchronize()

# 测
t0 = time.perf_counter()
for _ in range(10):
    b.copy_(a)
torch.cuda.synchronize()
t1 = time.perf_counter()

bytes_total = 4 * N * 2 * 10  # 2 = read + write
bw = bytes_total / (t1 - t0) / 1e9  # GB/s
print(f"HBM bandwidth (memcpy): {bw:.0f} GB/s")
print(f"Theoretical max ~3000 GB/s. Utilization: {bw/3000:.0%}")
```

**期望**：~2000-2500 GB/s（实测能到理论 70-80%）。

### 实验 6-B：用 nsys 抓一次 vLLM 推理

```bash
nsys profile -o vllm_trace \
  --trace=cuda,osrt --force-overwrite=true \
  .venv/bin/python -c "
from vllm import LLM, SamplingParams
llm = LLM(model='Qwen/Qwen2.5-0.5B-Instruct')
llm.generate('Hello world', SamplingParams(max_tokens=10))
"

# 看摘要
nsys stats vllm_trace.nsys-rep 2>&1 | head -50
```

**你会看到**：
- 哪些 CUDA kernel 跑得最频繁（attention, gemm 大概率前几名）
- 每个 kernel 的总时间和单次时间
- 这是你以后定位"为什么慢"的标准工具

### 实验 6-C：手动算一次 intensity

挑一个你写过的 PyTorch 操作，算它的 intensity：

```python
# 例：LayerNorm on (B=64, H=4096) fp16
# 算的：每元素 ~10 操作（mean, var, normalize）
#   total ops = 64 * 4096 * 10 = 2.6M ops
# 加载 + 写出：64 * 4096 * 2 bytes * 2 (in + out) = 1 MB
# intensity = 2.6M / 1M = 2.6 ops/byte → memory-bound
```

---

## 9. 自测 checklist

- [ ] GPU memory hierarchy 5 层各是什么？带宽差几个数量级？
- [ ] CPU cache 和 GPU SMEM 最大的差别是什么？
- [ ] Roofline 模型的 ridge point 怎么算？Blackwell ~多少 ops/byte？
- [ ] decode batch=1, 64, 256 的 intensity 各是多少？落在 roofline 的哪边？
- [ ] Naive attention 为什么 memory-bound？FlashAttention 怎么救？
- [ ] vLLM 的 KV cache 物理上在哪？为什么 attention 总是 memory-bound？
- [ ] Tensor Core 和 CUDA core 的区别？哪些操作受益？
- [ ] ncu 的 Achieved Occupancy 高代表什么？低呢？

---

## 10. 面试话术

### 短版（30 秒）

> "GPU 性能调优的第一性原理是 roofline——你被算力还是带宽卡住决定一切。LLM 推理里 prefill 是 compute-bound（落在 roof 下），decode 是 memory-bound（落在 memory roof 下）。HBM 带宽 3 TB/s 决定了 decode 单 token 的下限。所有 attention kernel 优化（FlashAttention、PagedAttention）本质都是减少 HBM 流量，把 intensity 从几提到几十几百。"

### 追问预判

| 追问 | 你的答 |
|---|---|
| "为什么 SMEM 不能更大？" | "SMEM 物理上和 L1 共享，每 SM 200+ KB 已是硬件极限。Blackwell 给到 228 KB。再大就要 redesign SM。" |
| "为什么 LLM 不用 fp32？" | "fp32 的 Tensor Core 算力只有 fp16 的 1/4，且 KV cache 翻倍占 HBM。fp16/bf16 是 LLM 推理的标准。" |
| "怎么知道我的 kernel 是 memory-bound 还是 compute-bound？" | "ncu 跑 roofline analysis，或者看 Memory Throughput vs SM Throughput 哪个先打到 80%。" |

---

## 下一站 → Day 7: FlashAttention

讲清楚为什么"在 SMEM 里 tile-by-tile 算 + online softmax" 能把 attention 从 memory-bound 救出来。
