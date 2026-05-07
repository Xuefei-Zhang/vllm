# Day 7 — Q10: FlashAttention 的核心 trick

> 昨天你认识了"为什么 naive attention 是 memory-bound"。今天讲 FlashAttention 怎么把它救出来——这是 2022 年最重要的 GPU kernel 创新。
>
> 阅读 ~35min / 实验 ~15min / 自测 ~10min

---

## 0. 回忆：naive attention 错在哪

```python
scores  = Q @ K.T          # [N, N] 写到 HBM
scaled  = scores / sqrt(d)  # 读 HBM, 写 HBM
probs   = softmax(scaled)   # 读 HBM, 写 HBM
output  = probs @ V         # 读 HBM, 写 HBM
```

N = 4096, head = 32 → 中间矩阵 32 × 4096 × 4096 × 2 byte = **1 GB 来回 HBM**。

**Roofline 上**：算力少（HBM 流量大），arithmetic intensity 低 → memory-bound。

---

## 1. ⭐ FlashAttention 的 3 个 trick

### Trick 1: Tiling（不写中间矩阵到 HBM）

把 Q, K, V 切成块（tile），每次只算一小块的 attention：

```
Q tile (Br × d)         K tile (Bc × d)
   │                       │
   └─── (Br × d) @ (d × Bc) = (Br × Bc) scores
                                       │
                              在 SMEM 里直接 softmax
                                       │
                              × (Bc × d) V tile
                                       │
                              累加到 output (Br × d)
```

**关键**：scores 矩阵 `(Br × Bc)` 一直留在 SMEM 里——SMEM 200+ KB 装得下小 tile。

**效果**：HBM 只需要读 Q, K, V，中间结果完全本地。流量从 O(N²) 降到 O(N)。

### Trick 2: Online Softmax（核心数学创新）

**问题**：softmax 需要"分母 = 所有 score 的 exp 之和"。如果你 tile-by-tile 算，**还没看完所有 K 之前不知道分母**！

教科书 softmax：
```python
exp_scores = exp(scores - max(scores))     # 第 1 遍：看全局最大值
probs = exp_scores / sum(exp_scores)        # 第 2 遍：算分母
```

**Online softmax 的 trick**：递推式维护 (m, l)，每来一个新 tile 都更新：

```
m_new = max(m_old, max(new_tile))                      # 更新全局最大
l_new = exp(m_old - m_new) * l_old + sum(exp(new_tile - m_new))  # 更新分母
output_new = exp(m_old - m_new) * output_old +         # 缩放历史输出
             exp(new_tile - m_new) * V_tile             # 加新贡献
```

**数学上等价于**最后再做一次完整 softmax，但**只需要遍历 K, V 一次**。

> 这个 trick 是 FlashAttention 论文的灵魂。值得你在纸上推一遍——你就真的"懂"了。

### Trick 3: Recomputation（FA-2 backward 才用）

训练时 backward 需要 scores 矩阵——重新算一遍而不是存。算 << HBM 读。

**推理时不需要 backward，所以这个 trick 不适用**。但提一下让你知道完整图景。

---

## 2. 算法伪代码（推理版本）

```python
# FlashAttention forward (简化推理版)
def flash_attn(Q, K, V, Br, Bc):
    # Q: [N, d], K: [N, d], V: [N, d]
    O = zeros([N, d])
    for i in range(0, N, Br):                  # 外层循环 Q tile
        Qi = Q[i:i+Br]                          # 装进 SMEM
        m_i = -inf                              # 当前 Q tile 的全局 max
        l_i = 0                                 # 当前 Q tile 的分母
        Oi = zeros([Br, d])
        
        for j in range(0, N, Bc):              # 内层循环 K, V tile
            Kj, Vj = K[j:j+Bc], V[j:j+Bc]      # 装进 SMEM
            
            Sij = Qi @ Kj.T / sqrt(d)           # SMEM 内矩阵乘 [Br, Bc]
            
            # online softmax 更新
            m_new = max(m_i, max(Sij, axis=-1))
            P = exp(Sij - m_new)
            l_new = exp(m_i - m_new) * l_i + sum(P, axis=-1)
            Oi = exp(m_i - m_new) * Oi + P @ Vj
            
            m_i, l_i = m_new, l_new
        
        O[i:i+Br] = Oi / l_i                    # 最终归一化
    
    return O
```

**计数 HBM 流量**：
- 读 Q: N × d
- 内循环每次读 K, V tile: 2 × Bc × d
- 外循环执行 N/Br 次 → 合计 K, V 读 N²×d / (Br × Bc) × Bc × 2 = 2N²d / Br

听起来 K, V 还是被读了 N/Br 次。但**关键**：
- Br 选大（比如 128）→ K, V 总共只被读 ~30 次而非 N 次
- 没有 `[N, N]` 中间矩阵的 HBM 流量

**净效果**：HBM 流量从 O(N²) 降到 O(N²/Br) ≈ O(N) 实际。

---

## 3. ⭐ 为什么 vLLM 用 FlashAttention

打开 [`vllm/v1/attention/backends/flash_attn.py`](file:///home/xuefeiz2/3rd/vllm/vllm/v1/attention/backends/flash_attn.py)（1244 行）。

vLLM 不自己实现 FlashAttention——用 NVIDIA / Meta 维护的 [vllm-flash-attn](https://github.com/vllm-project/flash-attention) 子模块（fork 自 Tri Dao 的原版）。

**vLLM 的工作 = 怎么把 PagedAttention（block table）和 FlashAttention（tiling）结合**。

### 难点：Block table + Tiling

FlashAttention 假设 K, V 是连续 tensor。但 vLLM 的 KV 散在不连续 block 里。

**解法**：扩展的 FlashAttention kernel 接受 **block_table 参数**，在内部 gather。

具体在 vllm-flash-attn 的 cu 源码里——你不必读，知道接口就行：

```python
# vllm/v1/attention/backends/flash_attn.py 调用
flash_attn_varlen_func(
    q, k_cache, v_cache,
    block_table=block_table,        # ← 关键：[batch, max_blocks_per_seq]
    cu_seqlens_q, cu_seqlens_k,     # 变长序列起止
    softmax_scale,
    causal=True,
)
```

**关键洞察**：FlashAttention + PagedAttention = "tiling 减少 HBM 流量" + "block table 解决变长 + 不连续"，**完全互补**。

---

## 4. vLLM 的 attention backend 选择

打开 [`vllm/v1/attention/backends/registry.py`](file:///home/xuefeiz2/3rd/vllm/vllm/v1/attention/backends/registry.py)，你会看到一组可选 backend：

```
flash_attn       ← 默认，性能最好
flashinfer       ← NVIDIA 自己的 attention，某些 case 更快
flex_attention   ← PyTorch 原生，灵活但慢
triton_attn      ← OpenAI Triton 写的
flash_attn_diffkv ← 处理 K/V 不同 head 数（GQA）
mla              ← DeepSeek 的 multi-head latent attention
mamba1/mamba2    ← state space model（不是 attention 但走同接口）
```

**为什么需要这层抽象**：
- 不同模型架构需要不同 attention（MLA / Mamba / GQA）
- 不同硬件支持不同 backend（FA 不支持 ROCm，Triton 各家通用）
- 不同精度有专门优化（FP8 attention）

**OS 类比**：Linux VFS。`open()` 系统调用对所有文件系统一致——下面接 ext4 / btrfs / NFS / FAT。

---

## 5. ⭐ Backend 在哪里被选中

打开 [`registry.py`](file:///home/xuefeiz2/3rd/vllm/vllm/v1/attention/backends/registry.py)，看 `_Backend` enum + `backend_name_to_enum` 函数。

选 backend 的逻辑（粗略，你自己读源码确认细节）：

1. 用户显式指定（环境变量 `VLLM_ATTENTION_BACKEND`）
2. 根据模型架构（MLA → mla 后端，Mamba → mamba 后端）
3. 根据硬件能力（sm_90+ 才能用 FA-3）
4. 根据 dtype（fp8 走专用 backend）
5. fallback 默认

**实验**：跑一次 vLLM，看日志里它选了什么 backend。你的 PRO 6000 (sm_120, Blackwell) 应该走 FA-3 或 FA-2。

---

## 6. ⚠️ 你之前发现的 vllm-flash-attn sm_80 编译问题

诊断方法：

```bash
# 1. 看 vllm-flash-attn 的实际编译产物
find . -path '*vllm_flash_attn*' -name '*.so' | xargs -I{} bash -c "echo '=== {} ==='; cuobjdump {} -lelf 2>/dev/null | head"

# 2. 跑一次推理，看是否报 "no kernel image is available for execution on the device"
.venv/bin/python -c "
import torch
print(torch.cuda.get_device_capability())  # 应该是 (12, 0)
from vllm import LLM, SamplingParams
LLM(model='Qwen/Qwen2.5-0.5B-Instruct').generate('test', SamplingParams(max_tokens=5))
"
```

如果跑得通 → FA 实际有 fallback 到通用 PTX 版本（sm_80 PTX 可被 sm_120 driver JIT 出 SASS）。性能可能不是最优但能跑。

如果报错 → 需要重编 vllm-flash-attn 子模块，加 `TORCH_CUDA_ARCH_LIST=12.0`。

**Day 10 我们专门解决这个**。

---

## 7. 🔬 动手实验

### 实验 7-A：测 FA vs Triton 性能对比

```python
# 文件：learning-journal/code-experiments/07_fa_vs_triton.py
import os, time

# 跑两次，分别用 FA 和 Triton
for backend in ["FLASH_ATTN", "TRITON_ATTN"]:
    os.environ["VLLM_ATTENTION_BACKEND"] = backend
    # 注意：要在 import vllm 之前设置环境变量
    # 不行的话另起进程跑
    
    print(f"\n--- backend = {backend} ---")
    # 在 subprocess 里跑实际测试
```

更现实的做法：写个 shell 脚本两次启动 Python：

```bash
for B in FLASH_ATTN TRITON_ATTN; do
    VLLM_ATTENTION_BACKEND=$B .venv/bin/python -c "
import time
from vllm import LLM, SamplingParams
llm = LLM(model='Qwen/Qwen2.5-0.5B-Instruct', max_num_seqs=1)
sp = SamplingParams(max_tokens=200, temperature=0)
t0 = time.perf_counter()
llm.generate('Hello'*100, sp)
t1 = time.perf_counter()
print(f'$B: {(t1-t0)*1000:.0f} ms')
"
done
```

**期望**：FA 比 Triton 快 20-50%（在 long context 上更明显）。

### 实验 7-B：观察 vLLM 启动时 backend 选择日志

```bash
.venv/bin/python -c "
from vllm import LLM
LLM(model='Qwen/Qwen2.5-0.5B-Instruct')
" 2>&1 | grep -i "attention\|backend"
```

应看到类似 "Using FlashAttention-2" 或 "Using FlashInfer" 的日志。

### 实验 7-C（可选，高难度）：在纸上推 online softmax

挑一个 6 元素数组 `[1, 5, 2, 8, 3, 4]`，分两个 tile `[1,5,2]` `[8,3,4]`：

1. 第一遍标准 softmax 算结果（验证用）
2. 用 online 方式：先看 tile 1，记 (m=5, l=, partial output)；再看 tile 2，更新 (m=8, l=, output)
3. 验证两边结果一致

推完你才"真懂"了 FlashAttention。

---

## 8. 自测 checklist

- [ ] FlashAttention 的 3 个 trick 是哪 3 个？（推理只用前 2 个）
- [ ] 为什么不写中间矩阵到 HBM 是关键？省了多少流量？
- [ ] Online softmax 怎么用 (m, l) 递推？为什么数学上和标准 softmax 等价？
- [ ] FlashAttention 和 PagedAttention 怎么结合？block_table 起什么作用？
- [ ] vLLM 为什么需要 attention backend 抽象层？类比 Linux 的什么？
- [ ] 你的 PRO 6000 上 vLLM 默认用哪个 backend？
- [ ] vllm-flash-attn 的 sm_80 编译问题怎么诊断？

---

## 9. 面试话术

### 短版（30 秒）

> "FlashAttention 的核心是用 tiling 把 attention 的 [N, N] 中间矩阵留在 SMEM 而不是 HBM——配合 online softmax 解决'不知道全局分母'的问题，HBM 流量从 O(N²) 降到 O(N)，把 attention 从 memory-bound 救出来。vLLM 把它和 PagedAttention 结合，FA kernel 接受 block_table 参数在内部 gather 散落的 KV。"

### 长版（2 分钟）

> "Naive attention 的瓶颈是中间 [N, N] 矩阵在 HBM 来回搬，N=4K 时单 head 32 MB，多 head 几百 MB。FlashAttention 的解法分三步：

> 1. **Tiling** —— Q, K, V 各切 tile，每次算一小块 attention，中间结果留 SMEM
> 2. **Online softmax** —— 用 (m_max, l_sum) 两个标量递推，遍历 K, V 一遍就能算出最终归一化结果，数学上等价
> 3. **Recomputation**（仅 backward）—— 训练时不存 scores，backward 时重算

> vLLM 用的是 Tri Dao 的 vllm-flash-attn 子模块，关键扩展是 kernel 接受 block_table 参数——这样 KV 散在不连续 block 里时也能 gather。本质上 FA 解决了'怎么省 HBM 流量'，PagedAttention 解决了'怎么管理散布的 KV'，两者完全互补。

> vLLM 还有一层 backend 抽象（registry.py 里的 _Backend enum），让不同模型架构（MLA、Mamba、GQA）和不同硬件能力（FA-2/FA-3/FlashInfer/Triton）走不同 backend，类似 Linux VFS。"

### 追问预判

| 追问 | 你的答 |
|---|---|
| "FA-3 比 FA-2 快多少？" | "FA-3 用 Hopper/Blackwell 的 async copy + warp specialization，比 FA-2 快 1.5-2x（H100/B200 上）。sm_90 以下用不了。" |
| "为什么 Triton 版本也存在？" | "Triton 是跨硬件的（AMD、Intel）。FA 只支持 NVIDIA。"|
| "FlashAttention 能用在 prefill 吗？decode 呢？" | "都能。prefill 是它的强项（N 大省得多）。decode 时 N=1，省的相对少，但 KV 长时仍有效。" |

---

## 下一站 → Day 8-10

Day 8: vLLM attention backend 抽象层深读（你自己写 dialogues，我审）
Day 9: PagedAttention CUDA kernel 阅读（看 paged_attention_v1.cu 数据流）
Day 10: Week 2 整合 + 解决 sm_80 编译问题
