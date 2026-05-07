# Q6 完整教案：从 Linux mm 到 PagedAttention

> 教学法：场景 → 直觉 → 系统原理 → vLLM 实现 → 动手实验 → 面试话术
>
> 阅读时间：~40 分钟 / 动手实验：~30 分钟
>
> 学完目标：你能讲清楚为什么需要 PagedAttention、它怎么工作、和 OS 虚拟内存什么关系，并能在 vLLM 源码里指认关键数据结构。

---

## 0. 前置：你必须先理解 KV Cache 是什么

我之前问你"KV cache 是什么、为什么每个用户要一份"——这里先补这个。**没这个前置，PagedAttention 学不进去**。

### Transformer 推理为什么需要 KV cache

LLM 一次推理生成 1 个 token，然后把这个 token 拼回输入，再生成下一个。看起来很浪费，但有个救命的优化叫 **KV cache**。

**核心事实**：Transformer 的 attention 公式是 `softmax(Q · K^T / √d) · V`。

- **Q**（Query）：来自**当前正在生成的那个 token**
- **K, V**（Key, Value）：来自**所有历史 token**（包括 prompt 里的 + 已经生成的）

当你生成第 N+1 个 token 时：
- **Q** 只需要算第 N+1 个位置的（1 个新值）
- **K, V** 需要前 N 个位置的全部 → **但前 N 个的 K/V 在生成第 N 个 token 时就算过了！**

> **优化**：把每个位置的 K, V 算一次后**存起来**，下一步直接复用。这块存储就是 **KV cache**。

### KV cache 的大小怎么算

每个 token 在每一层 transformer 都有一对 (K, V)。粗略公式：

```
KV cache size per token = 2 (K and V)
                        × num_layers
                        × num_heads
                        × head_dim
                        × bytes_per_element  (fp16 = 2)
```

举例 **Llama-7B**：32 层、32 头、head_dim=128 → 每 token ≈ **524 KB**。

| 用户上下文长度 | 单用户 KV cache |
|---|---|
| 1K token | 0.5 GB |
| 8K token | 4 GB |
| 32K token | 16 GB |

**100 个用户、每人 8K 上下文**：100 × 4 GB = **400 GB** —— 比模型权重 14 GB 大 **30 倍**。

### 关键洞察 ⭐

| 资源 | 大小 | 性质 |
|---|---|---|
| 模型权重 | 固定（Llama-7B = 14 GB） | 一次加载，所有用户共享 |
| **KV cache** | **动态、按用户、随对话增长** | **vLLM 的核心管理对象** |

> **vLLM 的本质** = 一个**专门管 KV cache 的内存管理器** + 一个**调度器**。
> 其它（推理本身）都是 PyTorch 干。

---

## 1. 场景：你是 vLLM 作者，你看到一个浪费

### 设定
- GPU 有 **80 GB** VRAM
- 模型权重占 14 GB，剩下 **66 GB 给 KV cache**
- 模型最大支持 8192 token 上下文
- 你要服务 3 个用户：
  - 用户 A：写了 200 字 prompt，回答了 600 字 → 共 **800 token**
  - 用户 B：30 字 prompt，回答了 170 字 → 共 **200 token**
  - 用户 C：长 prompt + 长回答 → 共 **5000 token**

### Naive 方案（一开始所有 LLM serving 都这么写）

> "我不知道用户最终会说多长，所以**先按最大 8192 给每个人留一片连续空间**。"

```
[Reserved 8192 for A][Reserved 8192 for B][Reserved 8192 for C]
       ↑↑↑                  ↑↑↑                  ↑↑↑
   actually used:         actually used:       actually used:
       800                    200                  5000
       (10%)                  (2.4%)               (61%)
```

### ✏️ 算一下浪费率

```
预留：3 × 8192 = 24576 token 的空间
实际：800 + 200 + 5000 = 6000 token
浪费：(24576 - 6000) / 24576 = 75.6%
```

**75% 的 GPU 显存被浪费**。这就是 vLLM 论文里 Figure 2 那张著名的"内存碎片"图。

### 还有第二种浪费：你算多了

要"接收"用户 A，你必须确保有 8192 连续空间——即使他实际只用 800。**这意味着 GPU 还能继续接用户的能力被严重高估了**：哪怕 GPU 物理上还有 60 GB 空闲，只要找不到一片"连续 8192 token"的空隙，新用户就被拒绝。

> 这就是**外部碎片**（external fragmentation）——总空间够，但**连续**空间不够。

---

## 2. 你的直觉应该开始响铃了

如果你是 OS 内核作者，看到上面这两个问题：

1. **总量够，连续不够** → 你想到什么？
2. **不知道最终多大，先按上限预留** → 你会怎么改？

> 大概率你的直觉是：**"别预留连续空间，按需分配小块就行了，用一张映射表把这些小块串起来。"**

恭喜——你**重新发明了 OS 的虚拟内存**。也是 PagedAttention 的核心思想。

---

## 3. 5 分钟搞懂 Linux mm 你需要的部分

不讲全部，只讲推理引擎用得到的**最小子集**。

### 3.1 为什么进程不直接用物理地址

40 年前的程序用物理地址，遇到 3 个致命问题：

1. **进程之间会互相踩内存**（A 写到 0x1000，B 也想写 0x1000）
2. **物理内存碎片化**（10MB 总空闲，但找不到 1MB 连续 → malloc(1MB) 失败）
3. **不能 swap 出去**（程序跑完才能腾地方）

OS 的解法：**给每个进程一份"虚拟地址空间"假象**。进程以为自己拥有连续 4GB（32-bit），实际背后是分散的物理内存。

### 3.2 分页机制：核心概念图

```
进程的虚拟地址空间 (假象)：
  0x1000  →  page 1  ──┐
  0x2000  →  page 2  ──┼──── Page Table ────┐
  0x3000  →  page 3  ──┘                    │
                                            ▼
物理内存 (真实)：
  Frame 47  ←  page 1
  Frame 12  ←  page 2     ← 离散的物理页
  Frame 89  ←  page 3
```

**关键设计**：

| 概念 | 含义 |
|---|---|
| **Page**（页） | 虚拟地址被切成固定大小（Linux 通常 4KB） |
| **Frame**（页框） | 物理内存被切成同样大小 |
| **Page Table** | 一张映射表：virtual page → physical frame |
| **Page Fault** | 访问未映射的页 → 触发 OS 处理（分配 frame / 从 swap 读回 / 报段错误） |

### 3.3 这个设计解决了什么

| 问题 | 怎么解决 |
|---|---|
| 进程隔离 | 每个进程自己的 page table → 看到不同的物理页 |
| **外部碎片消失** | 反正物理页可以散，连续的虚拟地址映射到不连续的物理页 |
| 内部碎片很小 | 最多浪费"最后半页" → 平均 2KB / 进程 |
| 按需分配 | 进程申请 1GB 不真分配 → 访问时才 page fault → 真分配 |

### 3.4 ⭐ 直接对应 vLLM

| Linux mm | vLLM PagedAttention |
|---|---|
| Page (4 KB) | **Block (默认 16 token)** |
| Frame (物理页框) | **GPU 上的物理 KV slot** |
| Page Table | **Block Table（每个请求一份）** |
| 进程 | **请求 (Request)** |
| `malloc()` | `KVCacheManager.allocate_slots()` |
| `free()` | `KVCacheManager.free()` |
| Page fault | （vLLM 静态分配，没有按需 page fault，但有 **eviction** 来腾空间，类似 swap） |
| Copy-on-write (fork) | **Prefix caching**（多请求共享相同前缀的 block） |

**这不是"借鉴"。这是"照搬"。**

vLLM 的 block size 默认是 **16 token**——和"4KB page"是一个性质的工程选择：太小则元数据多，太大则碎片多。

---

## 4. vLLM 源码对照（打开看）

### 4.1 物理 block 的元数据 — `KVCacheBlock`

打开 [vllm/v1/core/kv_cache_utils.py:113-159](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/kv_cache_utils.py#L113-L159)：

```python
@dataclass(slots=True)
class KVCacheBlock:
    """KV-cache block metadata."""

    # Block ID, ranging from 0 to num_gpu_blocks - 1.
    block_id: int           # ← 物理 frame number

    # Reference count.
    ref_cnt: int = 0        # ← 引用计数（多请求共享时 > 1）

    # Hash key for prefix caching.
    _block_hash: BlockHashWithGroupId | None = None  # ← 内容哈希

    # Doubly linked list for free blocks.
    prev_free_block: "KVCacheBlock | None" = None
    next_free_block: "KVCacheBlock | None" = None
```

**对照 Linux**：这就是 Linux 的 `struct page` 简化版！
- `block_id` = `page->index`
- `ref_cnt` = `page->_refcount`（引用计数）
- 双向链表挂在 free list 上 = `page->lru`（Linux 用 LRU 链表管理 page）

> **会心一笑时刻**：你以为你在学 LLM，其实你在学 OS。

### 4.2 物理池 — `BlockPool`

打开 [vllm/v1/core/block_pool.py:130-182](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/block_pool.py#L130-L182)：

```python
class BlockPool:
    def __init__(self, num_gpu_blocks: int, enable_caching: bool, ...):
        # All kv-cache blocks.  ← 所有物理 frame 的总池子
        self.blocks: list[KVCacheBlock] = [
            KVCacheBlock(idx) for idx in range(num_gpu_blocks)
        ]

        # Free block queue (doubly linked list of free blocks)
        self.free_block_queue = FreeKVCacheBlockQueue(self.blocks)

        # Cache for block lookup (hash → block)
        self.cached_block_hash_to_block: BlockHashToBlockMap = ...
```

**3 个核心数据结构**：

| 数据结构 | 作用 | Linux 对应 |
|---|---|---|
| `self.blocks` | 所有物理 block 的总数组 | `mem_map[]`（所有 page 数组） |
| `self.free_block_queue` | 空闲 block 双向链表 | `zone->free_area[]`（buddy allocator 的 free list） |
| `self.cached_block_hash_to_block` | hash → block 哈希表 | Linux page cache（按内容/inode 索引） |

### 4.3 上层管理器 — `KVCacheManager`

打开 [vllm/v1/core/kv_cache_manager.py:106-225](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/kv_cache_manager.py)：

关键方法对照 OS：

```python
class KVCacheManager:
    def get_computed_blocks(self, request) -> tuple[KVCacheBlocks, int]:
        """检查这个请求的 prompt 前缀是否已在缓存
        ↑ 类似 OS 的 page cache 命中检查
        """

    def allocate_slots(self, request, num_new_tokens, ...) -> ...:
        """为请求分配新 block（可能复用已缓存的）
        ↑ 类似 mmap() / brk() 给进程加内存
        """

    def free(self, request) -> None:
        """请求结束，引用计数 -1，可能回收
        ↑ 类似 munmap() / 进程退出时回收
        """

    def evict_blocks(self, block_ids) -> None:
        """显式驱逐某些 block
        ↑ 类似 OS 的 page reclaim
        """
```

### 4.4 一次完整调用流程

用户发请求 → vLLM scheduler 决定让它执行 → 调用 KVCacheManager：

```
1. get_computed_blocks(request)
   → 看这个 prompt 前缀（按 16 token 分块）哪些已在缓存
   → 命中 = prefix caching 省力 / 未命中 = 需要新算

2. allocate_slots(request, num_new_tokens)
   → 计算还需要多少 block（每 16 token 一个）
   → 从 free_block_queue popleft() 拿空闲 block
   → 不够 → 触发 eviction（驱逐 hash 缓存中 ref_cnt=0 的 block）
   → 把分配的 block_id 列表挂到 request 的 block_table 上

3. （forward pass 时，CUDA kernel 用 block_table 把分散的物理 block
   "拼接" 成逻辑上连续的 KV 序列做 attention）

4. free(request) when done
   → block 的 ref_cnt -= 1
   → 如果归 0，挂回 free_block_queue 末尾（变成 eviction 候选）
```

---

## 5. PagedAttention 怎么"在不连续的物理 block 上做 attention"

这是工程上最巧妙的地方。

**问题**：传统 attention kernel 假设 K, V 是连续 tensor。如果 KV 散落在不连续 block 里，cuBLAS 那种黑盒 GEMM 就用不了。

**解法**：**写一个新 CUDA kernel**，让每个 thread block 接收两个东西：
1. 一个 token 范围
2. **一张 block_table**（`[block_idx_0, block_idx_5, block_idx_2, ...]`）

kernel 内部用 block_table **gather** 出真实位置的 KV 来算。这就是 [csrc/attention/paged_attention_v1.cu](file:///home/xuefeiz2/3rd/vllm/csrc/attention/paged_attention_v1.cu) 干的事。

**对照 OS**：和 CPU 的 MMU 通过 page table 翻译每次内存访问的虚拟地址完全同构——只不过 GPU 上没有硬件 MMU，只能在 kernel 里"软件 MMU"。

---

## 6. 🔬 动手实验（在你的 PRO 6000 上跑）

### 实验 1：观察 vLLM 给你分配了多少 block

5 分钟。验证你刚学的"block pool"是真的存在。

```bash
cd /home/xuefeiz2/3rd/vllm
source scripts/runtime-trace.env
.venv/bin/python -c "
from vllm import LLM, SamplingParams
llm = LLM(model='Qwen/Qwen2.5-0.5B-Instruct', max_model_len=2048)
# 启动后会打印 'GPU KV cache size: N tokens' / 'Number of GPU blocks: M'
# M 就是 BlockPool.num_gpu_blocks
"
```

**你应该看到**类似的日志：
```
INFO ... GPU KV cache size: 524,288 tokens
INFO ... Maximum concurrency for 2048 tokens per request: 256.0x
```

→ `524288 / 16 = 32768 blocks`，每个 block 16 token。
→ "256x concurrency" 意思是：理论上能同时服务 256 个 2048-token 请求。

### 实验 2：手动 trace `allocate_slots` 看分配过程

20 分钟。用 Python 直接调 `KVCacheManager`，打印 block_id 看分配。

创建文件 [`learning-journal/code-experiments/01_block_pool_trace.py`](file:///home/xuefeiz2/3rd/vllm/learning-journal/code-experiments/01_block_pool_trace.py)：

```python
"""
实验：直接调 BlockPool，观察 block 分配。
不启动整个 vLLM engine。
"""
from vllm.v1.core.block_pool import BlockPool

pool = BlockPool(
    num_gpu_blocks=100,    # 假装 GPU 只有 100 个 block
    enable_caching=False,
    hash_block_size=16,
)

print(f"初始: {pool.get_num_free_blocks()} 个空闲 block")

# 模拟用户 A 来了，要 10 个 block (160 token)
blocks_A = pool.get_new_blocks(10)
print(f"分配给 A: {[b.block_id for b in blocks_A]}")
print(f"剩余空闲: {pool.get_num_free_blocks()}")

# 用户 B 也来了，要 5 个
blocks_B = pool.get_new_blocks(5)
print(f"分配给 B: {[b.block_id for b in blocks_B]}")

# A 用完释放
pool.free_blocks(blocks_A)
print(f"A 释放后空闲: {pool.get_num_free_blocks()}")

# B 又申请 3 个 → 复用 A 释放的 block
blocks_B2 = pool.get_new_blocks(3)
print(f"B 又拿了: {[b.block_id for b in blocks_B2]}")
print("观察：B 拿到的 block_id 是不是 A 之前用过的？说明发生了 frame 复用。")
```

跑：
```bash
.venv/bin/python learning-journal/code-experiments/01_block_pool_trace.py
```

**你应该看到**：B 第二次拿到的 block_id 包含 A 之前的 0,1,2。**这就是"物理 frame 被复用"**——和 OS 进程退出后页框被新进程使用是同一件事。

### 实验 3（可选）：cuda-gdb 单步 PagedAttention kernel

进阶，30 分钟。验证你的 debug build 有效。

```bash
cuda-gdb --args .venv/bin/python -c "from vllm import LLM; LLM(model='Qwen/Qwen2.5-0.5B-Instruct').generate('Hello')"
(cuda-gdb) break paged_attention_v1.cu:300   # 任选一行
(cuda-gdb) run
# 命中后能看 block_table 真实内容
```

---

## 7. 🎤 面试话术（背下来的版本）

下面这两段是你**面试时直接说**的版本，已经按"短、准、有 hook 让面试官追问"的标准磨过：

### 短版（30 秒，开场用）

> "我深度研究了 vLLM 的 KV cache 管理子系统。它本质上是一个**用户态的分页内存管理器**，借鉴了操作系统虚拟内存的思想——把 GPU 显存切成固定 16 token 的物理 block，每个请求维护一张 block table 做虚拟到物理的映射。和直接连续预留相比，这把 KV cache 的内存利用率从大约 40% 提到 95% 以上，serving 吞吐量提了 2-4 倍。这就是著名的 PagedAttention。"

### 长版（2 分钟，被追问"具体怎么实现的"）

> "核心是三个数据结构。第一是 `KVCacheBlock`，对应 OS 的 struct page，含 block_id、引用计数和 hash。第二是 `BlockPool`，维护一个所有物理 block 的数组、一个空闲 block 的双向链表（O(1) 取/放）、和一个内容哈希到 block 的查找表（用于 prefix caching）。第三是 `KVCacheManager`，对应 OS 的 mm 子系统，提供 allocate/free/evict 接口给上层 scheduler 调用。

> 最巧妙的是 attention kernel 本身——传统 GEMM 假设 K/V 是连续 tensor，但 paged 之后是散的。所以 vLLM 写了专门的 CUDA kernel `paged_attention_v1.cu`，让 kernel 在执行时通过 block_table 'gather' 出物理位置的 KV——本质就是软件实现的 MMU 翻译，因为 GPU 没有硬件 MMU。

> 设计上我觉得最妙的是 prefix caching：因为有引用计数和哈希表，多个请求如果 prompt 前缀相同（比如同一个 system prompt），它们的 block table 可以指向同一个物理 block，引用计数 +1。这就是 OS 里的 copy-on-write 在 LLM serving 上的对应物。"

### 面试官的追问预判 + 你的答法

| 追问 | 你的答 |
|---|---|
| "block size 为什么选 16？" | "Trade-off：太小元数据多，太大内部碎片多。16 是经验值，类似 OS 选 4KB page。可调，论文里测过 8/16/32 影响。" |
| "如果 block 用完了怎么办？" | "调用 evict_blocks，从 hash 缓存中找 ref_cnt=0 的（无活跃请求引用的）驱逐。LRU 策略由 free_block_queue 的链表顺序保证。" |
| "和 Linux 的 buddy allocator 比？" | "vLLM 简单很多——所有 block 同样大小，不需要 buddy 那种 2^k 合并。本质是单一 size class 的 slab allocator。" |
| "如果有几千个用户同时请求？" | "上面有 scheduler 决定哪些请求进入这一步 forward。block 分配只对'被调度执行的请求'发生，所以 BlockPool 不会被高并发请求量直接打爆。" |

---

## 8. 复习 checklist（48 小时后自测）

试着不看本文回答这些。能答 8/10 就算掌握：

- [ ] KV cache 是什么？为什么生成第 N+1 个 token 时不需要重算前 N 个的 K/V？
- [ ] 100 个用户、8K 上下文的 Llama-7B，KV cache 大概多大？
- [ ] Naive 连续预留有什么浪费？两类碎片分别是什么？
- [ ] OS 用什么机制解决"总量够但连续不够"？关键的两层抽象是什么？
- [ ] PagedAttention 的 block size 默认是多少？为什么不能太小或太大？
- [ ] `KVCacheBlock` 里有哪些字段？每个对应 OS 的什么概念？
- [ ] `BlockPool` 维护哪 3 个核心数据结构？各自 O(?) 复杂度？
- [ ] `allocate_slots` 调用时大概做哪几步？
- [ ] PagedAttention CUDA kernel 解决了什么问题（连续 GEMM 用不了）？
- [ ] Prefix caching 对应 OS 的什么经典机制？

---

## 9. 进阶阅读（可选）

按重要性排序：

1. **vLLM 论文 §4 Method**：[Efficient Memory Management for LLM Serving with PagedAttention](https://arxiv.org/abs/2309.06180) — 直接把上述全部正式描述一遍
2. **Linux mm 入门**：《Understanding the Linux Virtual Memory Manager》ch.2 (Page Table Management) —— **不要硬啃**，只看 page table 那 30 页
3. vLLM blog: <https://blog.vllm.ai/2023/06/20/vllm.html> — 配图很好

---

## 下一步

学完这个单元，你具备了下列能力：

- ✅ 知道 vLLM 在管什么内存（KV cache，不是权重）
- ✅ 能在源码里指认 BlockPool / KVCacheManager / KVCacheBlock
- ✅ 能用 OS 分页类比讲清楚 PagedAttention
- ✅ 能讨论设计权衡（block size、eviction、prefix caching）

接下来该学的是 **Q7（Continuous Batching）**——把"如何分配 KV"的问题解决了，下一步就是"如何决定下次 forward 带哪些请求"。这是 scheduler 的核心。
