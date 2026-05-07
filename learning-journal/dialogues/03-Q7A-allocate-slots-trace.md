# Day 2 — Q7-A: KVCacheManager.allocate_slots() 完整 trace

> Day 1 你认识了 BlockPool 这个"物理页帧池"。今天你要看的是它**上层的管理器**——`KVCacheManager`，这是 OS 类比里的 `mm_struct`。
>
> 阅读时间：~30 分钟 / 实验：~15 分钟 / 自测：~10 分钟

---

## 0. 回忆昨天的位置

```
  Scheduler                ← 决定哪个请求该跑（明天讲）
      ↓ 调用
  KVCacheManager           ← 今天的主角
      ↓ 调用
  KVCacheCoordinator       ← 多 group 协调（先跳过）
      ↓ 调用
  BlockPool                ← 昨天讲过：物理 block 池 + free list
      ↓ 维护
  KVCacheBlock × N         ← 物理 block 元数据
```

**类比 OS**：

| OS | vLLM |
|---|---|
| 应用 syscall (`mmap`) | Scheduler 调用 `allocate_slots` |
| `mm_struct`（进程内存描述符） | **`KVCacheManager`** |
| `vm_area_struct`（虚拟内存区） | `KVCacheBlocks`（请求的 block 列表）|
| Buddy allocator | `BlockPool` + free list |
| `struct page` | `KVCacheBlock` |

---

## 1. 一个请求的 KV 一生

下面的图是 vLLM 源码注释里直接抄的，是理解 `allocate_slots` 的钥匙。打开 [`kv_cache_manager.py:262-283`](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/kv_cache_manager.py#L262-L283) 对照着看：

```
----------------------------------------------------------------------
| < comp > | < new_comp > | < ext_comp >  | < new >  | < lookahead > |
----------------------------------------------------------------------
                                          |   < to be computed >     |
----------------------------------------------------------------------
                          |            < to be allocated >           |
----------------------------------------------------------------------
| Prefix-cached tokens from either vLLM   |
| or connector.                           |
----------------------------------------------------------------------
```

逐段翻译：

| 段 | 含义 | 谁出钱 |
|---|---|---|
| `comp` | 过去 step 已经算过的 token（已经有 KV）| 历史 |
| `new_comp` | 这次发现命中了 prefix cache 的 token（**直接复用别人的 KV**）| ⭐ 不需要分配，**白拿** |
| `ext_comp` | 外部 connector（如 P/D 分离架构里的 prefill 节点）算过的 KV | 也不算，但要分配槽位接收 |
| `new` | 这一步要新算的 token | 需要分配 |
| `lookahead` | speculative decoding 提前算的 draft token | 需要分配 |

> **关键洞察**：vLLM 不只在"请求一开始"分配 KV，而是**每个 scheduler step 都在动态分配**——因为 decode 阶段每生成 1 个 token 就可能需要新一个 block。

---

## 2. allocate_slots 的三阶段算法

打开 [`kv_cache_manager.py:300-307`](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/kv_cache_manager.py#L300-L307)，源码自己写了：

```
The allocation has three stages:
- Free unnecessary blocks in `comp` and check
   if we have sufficient free blocks (return None if not).
- Handle prefix tokens (`comp + new_comp + ext_comp`):
    - Free unnecessary blocks (e.g. outside sliding window)
    - Allocate new blocks for `ext_comp` tokens inside sliding window
- Allocate new blocks for tokens to be computed (`new + lookahead`)
```

### 阶段 1：可行性检查（admission control）

> "我手里 free block 够不够装下这个请求？不够就**拒绝**（返回 None），让上层 scheduler 决定 preempt 谁或推迟谁。"

**对照 OS**：和 `mmap()` 在物理内存不足时返回 ENOMEM 是同一回事——只不过 OS 还能 swap 出去，vLLM 可以 preempt 已 running 的请求腾空间。

### 阶段 2：处理 prefix（已经算过的 token）

两种情况：

- **vLLM 自己算过**（前几步留下的 KV）：调 `coordinator` 释放在 sliding window 之外的部分（节省内存）
- **外部算过**（如 P/D 分离里的 prefill 节点送来）：分配槽位，等 connector 把数据搬进来

> **OS 类比**：sliding window 截断 = OS 的 working set 压缩。"反正太久之前的内容用不上了，先把它们的物理页给别人用，要用再 swap-in"。

### 阶段 3：为 `new + lookahead` 真分配新 block

调 `BlockPool.get_new_blocks(n)`，从 free_block_queue 头部 popleft 出 n 个空闲 block。

返回 `KVCacheBlocks`（block 列表）给 scheduler，scheduler 把它挂到这个请求的 block_table 上。

---

## 3. ⭐ 真正在源码里走一遍

打开 [`kv_cache_manager.py:225-417`](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/kv_cache_manager.py#L225-L417)，对着下面这张"我应该看哪几行"清单：

| 行号区间 | 看这里学什么 |
|---|---|
| `225-236` | 函数签名 → 上层传进来什么参数（很多！但核心就 3 个：`request`, `num_new_tokens`, `new_computed_blocks`） |
| `262-283` | block layout 注释（上面的 ASCII 图）|
| `285-294` | 缩写表（`comp`, `new_comp`, `ext_comp`, `new`, `lookahead` 含义）|
| `300-307` | **三阶段算法说明** |
| `312-318` | 输入校验 |
| `335-344` | `full_sequence_must_fit` 的"严格 admission" 模式 |
| `345-417`（你自己读） | 三阶段的真实实现 |

**第一遍读法**：跳过你不认识的概念（spec decode, sliding window, encoder tokens, P/D connector），盯紧"主线"——`get_new_blocks` 在哪里被调。

---

## 4. 调用链：上面是谁、下面是谁

```python
# 上面：vllm/v1/core/sched/scheduler.py:387-510 (running 请求循环)
new_blocks = self.kv_cache_manager.allocate_slots(
    request, num_new_tokens, ...
)
if new_blocks is None:
    # 没空间 → preempt 一个 request → 重试
    self._preempt_request(...)

# 下面：vllm/v1/core/kv_cache_manager.py:225 (本文主角)
def allocate_slots(self, request, num_new_tokens, ...):
    # 三阶段算法 ...
    return self.coordinator.allocate_new_blocks(...)

# 再下面：vllm/v1/core/kv_cache_coordinator.py
# 协调多个 KV cache group（如 sliding-window + full attention 混合）

# 最下面：vllm/v1/core/block_pool.py:get_new_blocks
def get_new_blocks(self, num_blocks: int) -> list[KVCacheBlock]:
    # 从 free_block_queue popleft num_blocks 个
```

**记这 4 层调用关系**——后面所有教案都建立在这上面。

---

## 5. 🔬 动手实验

### 实验 2-A：跑模拟脚本看 block 分配

```bash
cd /home/xuefeiz2/3rd/vllm
.venv/bin/python learning-journal/code-experiments/02_allocate_slots_trace.py
```

你应该看到：
- 35-token prompt → 3 个 block（最后一个浪费 13 token 空间）
- 生成 20 token → 又需要 1 个新 block
- R1 释放 → free pool 恢复

### 实验 2-B：用 cuda-gdb 在真实推理上断点

20 分钟。验证 debug build 真的能 trace。

```bash
cd /home/xuefeiz2/3rd/vllm
source scripts/runtime-trace.env
.venv/bin/python -m pdb -c "b vllm/v1/core/kv_cache_manager.py:225" \
                        -c "c" \
                        -c "p request.request_id, num_new_tokens" \
                        -c "c" -c "q" \
  -c "from vllm import LLM; LLM(model='Qwen/Qwen2.5-0.5B-Instruct').generate('Hello world')"
```

> 注：cuda-gdb 用于 CUDA kernel 调试。Python 层用 `pdb` 即可。如果你想看 csrc 调用，再切 cuda-gdb。

**期望输出**：每生成几个 token 都会命中一次 `allocate_slots`，打印出请求 ID 和要分配的 token 数。

### 实验 2-C：观察 prefix caching 命中

```python
from vllm import LLM, SamplingParams

llm = LLM(model='Qwen/Qwen2.5-0.5B-Instruct', enable_prefix_caching=True)
sp = SamplingParams(max_tokens=20)

# 第一次 prompt
out1 = llm.generate("The quick brown fox jumps over the lazy dog. Continue:", sp)
# 第二次相同前缀（变后缀）
out2 = llm.generate("The quick brown fox jumps over the lazy dog. Tell me more:", sp)

# 看 metrics 里 prefix cache hit rate
```

第二次调用，前缀 KV 应该命中——直接复用第一次算的 block，`new_comp > 0`。

---

## 6. 自测 checklist（48h 后回来答）

- [ ] `allocate_slots` 的三阶段算法是哪三阶段？
- [ ] `comp / new_comp / ext_comp / new / lookahead` 各代表什么 token？
- [ ] 当 `allocate_slots` 返回 `None` 时，scheduler 会做什么？
- [ ] sliding window 截断对应 OS 的什么概念？
- [ ] prefix caching 命中时，新分配 block 数会变少还是变多？为什么？
- [ ] 为什么 vLLM 每个 scheduler step 都要调 `allocate_slots`，而不是请求初始一次性分配？
- [ ] BlockPool 和 KVCacheManager 各自承担什么职责？

---

## 7. 面试话术（短版，30 秒）

> "vLLM 的 KVCacheManager 类似 OS 的 mm_struct——它对每个请求维护一份 block 列表，按 scheduler step 增量分配。它的 `allocate_slots` 三阶段：先做 admission control 检查空间，再处理 prefix（包括 prefix cache 命中和 sliding window 截断），最后为新算的 token 真分配 block。空间不够会返回 None，让 scheduler 决定 preempt 谁。这种"按需增量分配"是支持 long context + 大并发的关键。"

---

## 下一站 → Day 3: Continuous Batching

明天讲 scheduler 本身：它怎么决定每一步带哪些请求进 forward？为什么传统的"等齐 batch 才发"不行？
