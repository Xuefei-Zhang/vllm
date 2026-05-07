# Day 3 — Q7-B: Continuous Batching ↔ 协作式调度

> 昨天你看完了"KV 怎么分配"。今天看"谁决定下一步带哪些请求进 forward"——这是 vLLM 性能的核心来源。
>
> 阅读 ~40min / 实验 ~25min / 自测 ~10min

---

## 0. 直觉先行：传统 batching 错在哪

### Naive 方案：静态 batch（HuggingFace transformers 默认）

```
t=0: 收 4 个请求 → 凑成 batch 发 GPU forward
     [req1: 100 token prompt → 生成 200 token]
     [req2: 100 token prompt → 生成 200 token]
     [req3: 100 token prompt → 生成 200 token]
     [req4: 100 token prompt → 生成  20 token]   ← 这个早完
     
t=20 step: req4 完成，但 batch 还在跑 → req4 的位置在 GPU 上**空转**
t=200 step: 所有都完成，**才能接收下一批**
```

**两个致命问题**：
1. **早完成的请求拖住整批** —— req4 跑完后，到 t=200 都在浪费 batch 槽位
2. **新请求要等整批结束** —— 第 5 个请求 t=10 来到，要等到 t=200 才能开始

**典型现象**：GPU 利用率 30%，但延迟还是高。

### 你的直觉应该响铃了

> "为什么不能某个请求完成后立即换上一个新请求？"

恭喜，你又重新发明了一个东西——这次是**协作式多任务调度**（cooperative multitasking）。

---

## 1. OS 类比：从批处理到分时

| 时代 | OS 调度模型 | 类似 LLM serving |
|---|---|---|
| 1950s | 批处理（Batch processing）| 静态 batch |
| 1960s | 协作式多任务（cooperative）| 早期 vLLM iteration-level |
| 1970s+ | 抢占式分时（preemptive）| **Continuous Batching + preemption** |

vLLM 的设计精确对应到 **协作式分时调度 + 资源限制下的抢占**。

### 协作式调度的关键性质

- **调度单位 = 一次"原子操作"** —— OS 里是 syscall / 时间片，**vLLM 里是一次 forward step**
- **每次原子操作结束，调度器重新决定下一批**
- 不需要中断请求"运行到一半"——它本来就是"算 1 个 token = 1 个 step"

### 抢占（preemption）的触发

OS：时间片用完 / 高优先级进程到来。

vLLM：**KV cache 不够用了**——必须 preempt 一个请求把它的 block 收回来。这就是为什么 `allocate_slots` 返回 None 时，scheduler 会 `_preempt_request`。

---

## 2. vLLM Scheduler 的核心数据结构

打开 [`vllm/v1/core/sched/scheduler.py:67-170`](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/sched/scheduler.py#L67-L170)，找到这几行：

```python
class Scheduler(SchedulerInterface):
    def __init__(self, ...):
        ...
        self.waiting = create_request_queue(self.policy)   # FCFS or Priority
        ...
        self.running: list[Request] = []
```

**两个核心容器**：

| 名称 | 类型 | 含义 | OS 对应 |
|---|---|---|---|
| `self.waiting` | RequestQueue | 等待入场的请求（还没分配 KV） | `runqueue` 里的 TASK_RUNNING 但还没上 CPU |
| `self.running` | `list[Request]` | 当前在 GPU 上推理的请求 | 在 CPU 上的进程 |

请求状态机（在 [`vllm/v1/request.py`](file:///home/xuefeiz2/3rd/vllm/vllm/v1/request.py) 的 `RequestStatus`）：

```
WAITING ──→ RUNNING ──→ FINISHED_*
   ↑           │
   │           ↓ (KV 不够)
   └──── PREEMPTED
```

打开 [`scheduler.py:807-826`](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/sched/scheduler.py#L807-L826) 看状态变换：

```python
self.running.append(request)
if request.status == RequestStatus.WAITING:
    ...
elif request.status == RequestStatus.PREEMPTED:
    ...
request.status = RequestStatus.RUNNING
```

---

## 3. ⭐ schedule() 主循环：vLLM 最重要的函数之一

打开 [`scheduler.py:352`](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/sched/scheduler.py#L352)，先看作者的注释（line 353-362）：

```python
def schedule(self) -> SchedulerOutput:
    # NOTE(woosuk) on the scheduling algorithm:
    # There's no "decoding phase" nor "prefill phase" in the scheduler.
    # Each request just has the num_computed_tokens and
    # num_tokens_with_spec. ...
    # At each step, the scheduler tries to assign tokens to the requests
    # so that each request's num_computed_tokens can catch up its
    # num_tokens_with_spec. This is general enough to cover
    # chunked prefills, prefix caching, speculative decoding, ...
```

**这是整个 vLLM 调度器的设计哲学**：⭐⭐⭐

> **不存在 prefill 和 decode 两个阶段**。每个请求就是"还差多少 token 没算"。scheduler 每一步就是把 token budget 分给这些请求，让它们各算一些。

这就完全统一了：
- 大 prompt 第一次进来（"prefill"）= 一次性给它算很多 token
- decode 中（"decode"）= 给它算 1 个 token
- chunked prefill = prefill 太大就分多次，每次算一块

**全是同一个机制**。这是一个非常深的设计统一。

### schedule() 的两段循环

```python
# 段 1: 先调度 RUNNING 的请求 (line 388-510)
while req_index < len(self.running) and token_budget > 0:
    request = self.running[req_index]
    num_new_tokens = ...  # 算这个请求这步要算几个 token
    new_blocks = self.kv_cache_manager.allocate_slots(request, num_new_tokens, ...)
    if new_blocks is None:
        # KV 不够 → preempt 优先级最低的请求
        preempted_req = max(self.running, key=...)  # line 480
        self.running.remove(preempted_req)
        self._preempt_request(preempted_req, ...)   # 释放它的 KV，状态改 PREEMPTED
        continue  # 重试当前请求
    ...

# 段 2: 再尝试从 waiting 队列拉新的进来 (line 571+)
while (self.waiting or self.skipped_waiting) and token_budget > 0:
    if len(self.running) == self.max_num_running_reqs:
        break  # 跑满了
    request = self.waiting.peek_request()
    new_blocks = self.kv_cache_manager.allocate_slots(...)
    ...
    self.running.append(request)
    request.status = RequestStatus.RUNNING
```

**关键洞察**：

1. **每一步都重新决策** —— 不像静态 batch 决定一次跑到底
2. **token_budget** = 这一步整个 batch 能算的最大 token 数（防止单 step 太久）
3. **preemption 是必备** —— 单纯靠"等空间"会饿死 / 死锁
4. **段 1 优先于段 2** —— 已 running 的请求优先级高于新请求（避免 starvation 反方向）

---

## 4. Token Budget：为什么需要这个东西

`token_budget = self.max_num_scheduled_tokens`（line 371）。

**问题场景**：一个 batch 里有 100 个请求，每个 1 token decode（decode 是 memory-bound，并行成本极低），合计 100 token——很快。

但如果同时来个 8K prompt 的新请求，要全 prefill——这一步就要算 8K + 100 = 8100 token，**整个 step 时间被这个新请求拖到几百 ms**，所有 decode 用户都感受到延迟尖峰。

**vLLM 解法**：限制单 step 总 token 数（比如 2048）。8K prompt → 拆成 4 步走（**chunked prefill**）。每步只算 2K 个新 token。

**OS 类比**：CPU 时间片。Linux 默认时间片 ~1ms，防止某个进程一上来就霸占 CPU 几百 ms。vLLM 的 token budget = GPU 时间片。

---

## 5. Preemption 详解（line 480-510）

打开看具体实现：

```python
preempted_req = max(
    self.running,
    key=...  # 找"最该被抢的"请求
)
self.running.remove(preempted_req)
...
self._preempt_request(preempted_req, scheduled_timestamp)
```

`_preempt_request` 在 [line 952](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/sched/scheduler.py#L952)，做的事：

1. 释放它的 KV blocks（`kv_cache_manager.free(request)`）
2. 把请求状态改成 PREEMPTED
3. 把请求重新塞回 waiting 队列头部

**两种 preemption 策略**（论文提到）：
- **Recompute**（vLLM 默认）：丢弃 KV，下次重新算 prefill。简单。
- **Swap**：把 KV 搬到 CPU 内存，下次搬回。复杂但避免重算。

这就是 [`vllm/v1/kv_offload/`](file:///home/xuefeiz2/3rd/vllm/vllm/v1/kv_offload/) 子系统在做的事——**你的 good-first-PR 候选区之一**。

---

## 6. 🔬 动手实验

### 实验 3-A：观察 schedule() 调用频率

20 分钟。在 scheduler 上加 log，跑一次推理，看每个 step 调度了几个请求。

```bash
cd /home/xuefeiz2/3rd/vllm
git stash  # 保存现状
```

编辑 `vllm/v1/core/sched/scheduler.py`，在 `schedule()` 方法**末尾** return 之前加：

```python
import logging
_dbg = logging.getLogger("sched_dbg")
_dbg.warning(
    f"[STEP] running={len(self.running)} waiting={len(self.waiting)} "
    f"scheduled_tokens={sum(num_scheduled_tokens.values())}"
)
```

然后跑（启动并发请求让你能看到现象）：

```python
# 文件：learning-journal/code-experiments/03_scheduler_observe.py
import asyncio
from vllm import LLM, SamplingParams

llm = LLM(model="Qwen/Qwen2.5-0.5B-Instruct", max_num_seqs=8)
sp = SamplingParams(max_tokens=50)

# 同时发 5 个请求
prompts = [
    "Tell me a story about " + topic 
    for topic in ["dragons", "robots", "oceans", "stars", "forests"]
]
outputs = llm.generate(prompts, sp)
for o in outputs:
    print(o.outputs[0].text[:60])
```

跑：
```bash
.venv/bin/python learning-journal/code-experiments/03_scheduler_observe.py 2>&1 | grep "\[STEP\]" | head -20
```

**你应该看到**：
- 第一步：`running=5 waiting=0 scheduled_tokens=高`（5 个请求都进 prefill）
- 后续 step：`running=5 waiting=0 scheduled_tokens=5`（5 个 decode，每个 1 token）
- 个别请求完成后：`running=4 ...`

**学到什么**：
- 同一 batch 里有的在 decode 有的在 prefill
- decode 的 step 极便宜（5 token / step）—— GPU 主要时间花在 prefill 上

记得跑完 `git stash pop` 还原（或丢掉这个改动 `git checkout vllm/v1/core/sched/scheduler.py`）。

### 实验 3-B：触发 preemption 看现象

设置很小的 max KV space，让 vLLM 必须 preempt：

```python
llm = LLM(
    model="Qwen/Qwen2.5-0.5B-Instruct",
    max_num_seqs=4,
    gpu_memory_utilization=0.3,  # 故意压小 KV cache
    max_model_len=2048,
)
# 然后 8 个长 prompt 同时打进去 → 必然触发 preemption
```

观察日志里有没有 `[STEP] running=` 数字突然下降——那就是 preemption 在发生。

---

## 7. 自测 checklist

- [ ] vLLM scheduler 的两个核心队列叫什么？
- [ ] 请求有几个状态？怎么转换？
- [ ] 为什么源码注释说"there's no decoding phase nor prefill phase"？这个统一的好处是什么？
- [ ] token_budget 解决什么问题？OS 里对应什么概念？
- [ ] 什么时候触发 preemption？preempt 谁？
- [ ] Recompute vs Swap 两种 preemption 策略的 trade-off？
- [ ] schedule() 为什么先调度 running 再调度 waiting？反过来会怎样？
- [ ] chunked prefill 在源码里是怎么实现的（提示：不是单独逻辑，是 token_budget 的副产品）

---

## 8. 面试话术

### 短版（30 秒）

> "vLLM 的 continuous batching 本质是协作式调度——每次 forward step 是一个原子调度单位。每步重新决定带哪些请求、各算多少 token，所以早完成的请求立刻让位给新请求。配套机制：token budget 限制单 step 时长（类似 CPU 时间片，防止单个长 prompt 拖累所有 decode 用户）；KV 不够时主动 preempt（类似 OS 在内存压力下 swap 进程）。"

### 长版（2 分钟）

> "vLLM scheduler 最深的设计是：'没有 prefill 阶段也没有 decode 阶段'。每个请求只有'还差多少 token 没算'，scheduler 把每一步的 token budget 分给这些请求。这一个抽象统一了 chunked prefill、continuous batching、prefix caching、speculative decoding——它们都是'怎么决定每个请求这一步算几个 token'的不同策略。

> 实现上有 waiting 和 running 两个队列。schedule() 主循环先扫 running 给每个请求要新算的 token 分配 KV——空间不够就触发 preemption，挑一个请求踢回 waiting 头部。然后再从 waiting 拉新请求进来，直到达到 max_num_seqs 或 token_budget 用完。

> 整个机制对应 OS 的协作式调度 + 资源约束下的抢占——time slice = token budget，process = request，CPU = GPU SM，page fault = KV exhaustion。"

### 追问预判

| 追问 | 你的答 |
|---|---|
| "为什么不抢占式而是协作式？" | "GPU 上没有'中断当前 kernel'的便宜机制。每个 forward step 是天然原子单位，等 step 结束再决策成本最低。" |
| "preemption 频繁会怎样？" | "Recompute 模式下重算 prefill，浪费算力；如果一个长请求被反复 preempt 会饿死。所以实践上要么调大 KV cache，要么用 swap 模式。" |
| "max_num_seqs 怎么定？" | "trade-off：太大 KV cache 不够频繁 preempt；太小 GPU SM 利用率低。看 model + 上下文长度 + GPU memory 经验调。" |

---

## 下一站 → Day 4: Prefill vs Decode 失衡

讲清楚为什么 prefill 是 compute-bound、decode 是 memory-bound——以及为什么这迫使 vLLM 把它们混在一起跑（chunked prefill + continuous batching）。
