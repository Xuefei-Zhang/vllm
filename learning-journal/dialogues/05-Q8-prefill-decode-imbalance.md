# Day 4 — Q8: Prefill vs Decode 的本质失衡

> 这是 LLM serving 整个领域的"第一性原理"问题。理解这个，你就能秒懂为什么所有现代 serving 系统（vLLM, SGLang, TensorRT-LLM）的设计长这样。
>
> 阅读 ~35min / 实验 ~20min / 自测 ~10min

---

## 0. 一个反直觉的事实

| 操作 | 算 1 个 token 用多少 FLOPs | 加载多少 model weight bytes |
|---|---|---|
| Prefill 算 1 个 token（N 个 token 的 prompt 一起算）| ~2P FLOPs（P = 模型参数量） | **总共加载一次 weights** |
| Decode 算 1 个 token | ~2P FLOPs | **每个 token 都要加载一次** |

**反直觉点**：
- Prefill 算 1000 个 token 的成本 ≈ Decode 算 1 个 token 的 1000 倍 GPU 时间？**错。**
- 实际：**Prefill 1000 token 比 Decode 1000 token 快很多**。因为 prefill 把 1000 token 摊到一次 weight 加载里。

---

## 1. 为什么 Prefill 是 Compute-Bound

**场景**：用户发 1000 token prompt。

prefill 的 GEMM 形状：`[1000, hidden] × [hidden, hidden]` —— 这是大矩阵乘法。

**GPU 上的 GEMM 性质**：
- 算力 ≥ 100 TFLOPs (Blackwell 上 fp16 ~600 TFLOPs)
- 一旦矩阵足够大，**算的时间 >> 加载 weights 的时间**
- 这就是 **compute-bound**：GPU 的 SM 在拼命算，HBM 带宽没占满

**Roofline 模型解释**：

```
ops/byte (arithmetic intensity)
   ↑
   │       ╱  compute roof
   │      ╱
   │     ╱
   │    /  ← Prefill 在这里
   │   /
   │__/_______________________
       memory roof
```

Prefill 的 arithmetic intensity ≈ 1000（每加载 1 byte 算 1000 次操作），落在 compute roof 下面，被 compute 限制。

---

## 2. 为什么 Decode 是 Memory-Bound

**场景**：用户已经有 1000 token 上下文（KV cache 在 GPU 里），现在要生成第 1001 个 token。

decode 的 GEMM 形状：`[1, hidden] × [hidden, hidden]` —— **批大小 = 1 的退化矩阵乘法**！

更要命的是 attention：要从 KV cache 读 1000 个 token 的 K, V（**524 KB × 1000 = 0.5 GB 的内存读取**）来算 1 个新 token 的 attention。

**GPU 上的退化 GEMM 性质**：
- 矩阵太小 → SM 没几个在工作
- 主要时间在 **从 HBM 加载 weights + KV** 到 SRAM
- HBM 带宽：Blackwell ~3 TB/s，加载完整 model weights（14 GB Llama-7B）就要 ~5 ms
- 这就是 **memory-bound**：HBM 带宽打满了，SM 大多数时间在等数据

**Roofline 上的位置**：

```
ops/byte
   ↑
   │       ╱  compute roof
   │      ╱
   │     ╱
   │    ╱
   │   ╱
   │  /__________________
   │_/* ← Decode 在这里
       memory roof
```

Decode 的 arithmetic intensity ≈ 1（加载 1 byte 算 1 次），落在 memory roof 下面，被带宽限制。

---

## 3. ⭐ 核心数字感（必须记住）

以 **Llama-7B fp16** + **Blackwell（~600 TFLOPs fp16, ~3 TB/s HBM）** 为例：

| 操作 | 时间估算 | 谁的瓶颈 |
|---|---|---|
| Prefill 1024 token | ~7 ms（compute）| SM |
| Decode 1 token（batch=1）| ~5 ms（memory）| HBM |
| Decode 1 token（batch=64）| ~7 ms（仍 memory，但摊到 64 个用户）| HBM |

**关键洞察**：
- Decode batch=1 vs batch=64 时间几乎一样（都是加载一次 weights，算 64 次的算力是富余的）
- **Decode 的吞吐量 ≈ batch 大小 × 1 / decode_latency**
- batch 越大，每用户的 decode 越便宜——这就是**为什么 continuous batching 这么重要**

---

## 4. 这种失衡导致的灾难场景

### 场景 A：Decode-only 用户中混进一个 Prefill

```
batch = [decoding user × 64]   →  step 时间 ~7 ms
然后混进一个长 prompt: [decoding × 64, prefill 8192]
→  step 时间 ~50+ ms（被 prefill 拖死）
→  64 个 decode 用户都感受到 latency 尖峰
```

**这就是为什么需要 chunked prefill**：把 8192 拆成 4×2048 chunk，每步只算 2048 → step 时间 ~15 ms 而不是 50 ms。延迟尖峰从 50 ms 降到 15 ms。

### 场景 B：Prefill-only batch（不合理但常见）

```
batch = [4 个 prompt 在 prefill]   →  GPU 全忙在 SM
→  HBM 带宽闲着
→  浪费一半硬件能力
```

**vLLM 解法**：尽量让 prefill 和 decode 混批 —— 让 SM 算 prefill 的同时，HBM 带宽用来加载 decode 的 weights。**两类瓶颈互补**。

---

## 5. 看源码：vLLM 怎么实现混批

打开 [`vllm/v1/core/sched/scheduler.py:352`](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/sched/scheduler.py#L352) 的 `schedule()`。

**关键设计**（昨天 Q7-B 已经讲过）：

```python
# 没有"prefill 阶段"和"decode 阶段"的概念
# 每个 request 只有 num_computed_tokens
# 每步：在 token_budget 内，给每个 running request 分一些 token 算
```

具体看 line 408-415：

```python
num_new_tokens = (
    request.num_tokens_with_spec
    + request.num_output_placeholders
    - request.num_computed_tokens
)
if 0 < self.scheduler_config.long_prefill_token_threshold < num_new_tokens:
    num_new_tokens = self.scheduler_config.long_prefill_token_threshold
num_new_tokens = min(num_new_tokens, token_budget)
```

逐句翻译：

1. `num_new_tokens = 还差的 token 数` —— prefill 中的请求差很多，decode 中的差 1
2. `if long_prefill_token_threshold ...` —— 如果差太多（长 prefill），**截断到阈值**（chunked prefill）
3. `min(num_new_tokens, token_budget)` —— 不能超过这步的总预算

**配置项**：
- `long_prefill_token_threshold`（默认通常 2048-4096）：单请求单 step 最多算几个 token
- `max_num_batched_tokens`（即 token_budget）：整 batch 一步最多算几个 token

---

## 6. OS 类比：CPU-bound vs IO-bound 进程混合调度

| OS | LLM serving |
|---|---|
| CPU-bound process（编译、计算）| **Prefill request**（compute-bound）|
| IO-bound process（数据库、网络）| **Decode request**（memory-bound）|
| 单跑 CPU-bound → IO 闲 | 单跑 prefill → HBM 闲 |
| 单跑 IO-bound → CPU 闲 | 单跑 decode → SM 闲 |
| 混跑 → 资源利用最大化 | **chunked prefill + continuous batching → 利用率最大化** |
| 时间片防止 CPU-bound 霸占 | **token_budget 防止长 prefill 霸占** |

40 年前 Linux 内核工程师做过的事，今天 LLM serving 工程师在 GPU 上重新做一遍。

---

## 7. 两个延迟指标（面试必背）

| 指标 | 定义 | 主要瓶颈 | 怎么优化 |
|---|---|---|---|
| **TTFT** (Time To First Token) | 用户提交 → 看到第一个字 | **Prefill 时间** | 更快的 prefill kernel、prefix caching、disaggregated prefill |
| **ITL** (Inter-Token Latency) | 第 N 个 token → 第 N+1 个 token | **Decode 时间** | 更大 batch、KV cache 压缩、speculative decoding |

**注意 trade-off**：
- 大 batch 提升吞吐和 ITL（每用户 decode 便宜），但伤 TTFT（新请求要等当前 batch 完成）
- chunked prefill 平滑 ITL，但稍微慢一点 TTFT

---

## 8. 现代解法：Disaggregated Prefill (P/D 分离)

更激进的解法（vLLM 也在做，见 [`vllm/distributed/kv_transfer/`](file:///home/xuefeiz2/3rd/vllm/vllm/distributed/kv_transfer/)）：

> "既然 prefill 和 decode 性质完全不同，干脆把它们放在**不同 GPU 上**。"

```
[Prefill GPU group]      [Decode GPU group]
   compute-bound          memory-bound
   要大 SM 算力           要大 HBM 容量装多用户 KV
       │                       ↑
       └─── KV transfer ────────┘
           (网络/NVLink 传 KV)
```

P/D 分离后：
- Prefill 节点专心跑大 batch GEMM，SM 利用率 90%+
- Decode 节点用大 batch 摊 weights load，吞吐量翻倍
- 代价：要跨节点传 KV（每 token 0.5 MB × 32 layer = ~MB 级别）

这是 SOTA serving 系统（DistServe, SGLang）正在卷的方向。

---

## 9. 🔬 动手实验

### 实验 4-A：测你的 PRO 6000 上 prefill 和 decode 的实际时间

```python
# 文件：learning-journal/code-experiments/04_prefill_decode_latency.py
import time
from vllm import LLM, SamplingParams

llm = LLM(model="Qwen/Qwen2.5-0.5B-Instruct", max_num_seqs=64)
sp = SamplingParams(max_tokens=100, temperature=0)

# 测 prefill：长 prompt + 极少 decode
long_prompt = "The quick brown fox " * 200  # ~800 token
sp_short = SamplingParams(max_tokens=1)

t0 = time.perf_counter()
out = llm.generate(long_prompt, sp_short)
t1 = time.perf_counter()
print(f"Prefill ~800 tok + 1 decode: {(t1-t0)*1000:.1f} ms")

# 测 decode：短 prompt + 多 decode
sp_long = SamplingParams(max_tokens=200, temperature=0)
t0 = time.perf_counter()
out = llm.generate("Hello", sp_long)
t1 = time.perf_counter()
print(f"Prefill ~5 tok + 200 decode: {(t1-t0)*1000:.1f} ms")
print(f"  → 平均每 token decode: {(t1-t0)*1000/200:.2f} ms")

# 测 batched decode：多用户同时 decode
prompts = ["Hello"] * 32
t0 = time.perf_counter()
outs = llm.generate(prompts, sp_long)
t1 = time.perf_counter()
print(f"32 用户 × 200 decode: {(t1-t0)*1000:.1f} ms")
print(f"  → 平均每用户每 token: {(t1-t0)*1000/(32*200):.3f} ms")
```

**你应该看到**：
- 单用户 decode ~5 ms/token
- 32 用户 decode 总时间不到 32× —— 因为每 step 摊 weights load
- Prefill 800 token 不会比 decode 1 token 慢 800 倍

### 实验 4-B：观察 chunked prefill 阈值的影响

```python
# 同一个长 prompt，分别用不同 long_prefill_token_threshold 跑
# 看 TTFT 和 ITL 的变化

for thresh in [512, 2048, 8192]:
    llm = LLM(
        model="Qwen/Qwen2.5-0.5B-Instruct",
        long_prefill_token_threshold=thresh,
    )
    # ... 测试 + 打印 TTFT、ITL
```

阈值小：TTFT 大（多步才完成 prefill），但 decode 用户的 ITL 更稳定。

---

## 10. 自测 checklist

- [ ] 为什么 prefill 是 compute-bound、decode 是 memory-bound？
- [ ] Roofline 模型上 prefill 和 decode 各落在哪里？
- [ ] decode batch=1 和 batch=64 谁更快？为什么？
- [ ] chunked prefill 解决什么问题？源码上是怎么实现的（哪一行）？
- [ ] TTFT 和 ITL 各自被什么瓶颈主导？
- [ ] 为什么 prefill 和 decode 混批比单独跑都好？
- [ ] P/D 分离的动机和代价分别是什么？
- [ ] OS 里 CPU-bound 和 IO-bound 进程混合调度 → 类比 LLM 哪两类请求？

---

## 11. 面试话术

### 短版（30 秒）

> "LLM 推理有两个性质截然不同的阶段：prefill 是 compute-bound（大 GEMM，SM 满载），decode 是 memory-bound（小 GEMM，HBM 带宽满载）。它俩混批跑能让两个瓶颈互补。这就是 vLLM 等现代 serving 系统的核心设计——没有真正的 prefill/decode 阶段划分，scheduler 每步只看'谁还差多少 token 没算'，再用 chunked prefill 防止单个长 prompt 拖延 decode 用户的 ITL。"

### 长版（2 分钟）

> "在 GPU 上算 1 个 token 不只是 FLOPs 的问题——还要看 arithmetic intensity。Prefill 一个 1000-token prompt 的 GEMM 形状是 [1000, hidden] × [hidden, hidden]，arithmetic intensity 几百以上，落在 roofline 的 compute roof 下面；decode 是 [1, hidden] × [hidden, hidden] 的退化 GEMM，intensity 接近 1，落在 memory roof 下面。所以 prefill 单 token 比 decode 单 token 快得多，因为它把 weight load 摊到了 1000 token 上。

> 这导致两个延迟指标天差地别：TTFT 由 prefill 主导，ITL 由 decode 主导。优化它们的手段也不一样——TTFT 看 kernel 优化和 prefix cache 命中，ITL 看 batch size 和 KV cache 压缩。

> vLLM 把它们混批跑，让 prefill 用 SM、decode 用 HBM，硬件利用率最大化。chunked prefill 进一步把长 prompt 切片，避免单步 80 ms 的尖峰拖累几十个 decode 用户。这个抽象在源码里特别干净——`schedule()` 函数完全不区分两个阶段，只看 num_computed_tokens 差多少。"

### 追问预判

| 追问 | 你的答 |
|---|---|
| "Speculative decoding 解决哪个？" | "ITL。decode 阶段一次算多个 draft token，但它们仍然只加载一次 weights。" |
| "GPU memory utilization 调高就能装更多用户对吧？" | "对，但 trade-off：KV 越多 → arithmetic intensity 仍低 → ITL 不会自动变好。还是要看 batch 内同时 decode 的并发数。" |
| "为什么不用 batch 等待凑齐再发？" | "等待 = TTFT 增加。continuous batching 用'每步都重新组 batch'消除等待，是 streaming serving 的必要条件。" |

---

## 下一站 → Day 5: Week 1 整合 + 模拟面试

把 Day 1-4 的内容串成一张"请求生命周期图"，并接受我的 30 分钟模拟面试拷打。
