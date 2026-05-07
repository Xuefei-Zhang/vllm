# 30-Day vLLM 核心贡献者冲刺计划

> **目标（一句话）**：30 天后，你能在 vLLM 项目里指认任意一个核心子系统的关键代码、用 OS/系统原理解释它的设计、独立提交并 merge 第一个有意义的 PR，并在面试中以"我深度研究并贡献了 vLLM 的某子系统"为锚点讲清楚自己的能力。
>
> **强度**：全职 6-8h/天，5 天/周 + 2 天 buffer。共 22 个工作日。
>
> **教学法**：双线绑定（vLLM 概念 + 对应 OS/系统原理）。每个单元产出 = 1 个教案 markdown + 1 个动手实验脚本 + 1 段面试话术。

---

## 全景图：4 周 + 1 个 PR

```
Week 1  (Day 1-5)   ──  KV Cache + Scheduler 基础           [vllm/v1/core/]
Week 2  (Day 6-10)  ──  Attention 后端 + GPU 内存层级       [vllm/v1/attention/]
Week 3  (Day 11-15) ──  CUDA Kernel + 分布式基础            [csrc/, vllm/distributed/]
Week 4  (Day 16-22) ──  挑选真实 PR + 写出来 + merge         [选一个 good-first-area]
Buffer  (Day 23-30)            ← 给 PR review 来回 + 复习 + 面试演练
```

**每一周固定节奏**：
- Day N 早上：读教案（如果当天有）+ 读源码
- Day N 下午：动手实验（trace / 改 / break / 修）
- Day N 晚上：写"今日学到什么"到 `learning-journal/dialogues/dayNN-*.md`
- 每周五：自测 checklist + 给我对一次"面试模拟问答"

---

## Week 1 — KV Cache + Scheduler 基础（最关键的一周）

> **本周目标**：你能脱稿讲清楚一个请求从 `LLM.generate()` 到 GPU forward 之间，KV 怎么分配、调度器怎么决定它进哪一批。

### Day 1（周一）— Q6 消化日 ✅ 已完成教案
- **早**：读 [Q6 教案](file:///home/xuefeiz2/3rd/vllm/learning-journal/dialogues/02-Q6-pagedattention-and-linux-mm.md)（~40 min）
- **下午**：跑 Q6 实验 1（5 min）+ 实验 2（20 min），把 BlockPool 真实分配过程跑出来看
- **晚**：在 `dialogues/03-day1-reflection.md` 写：(a) 你能用自己的话讲 PagedAttention 吗 (b) 哪里还卡
- **交付**：实验脚本运行截图 + 反思笔记
- **验收**：能脱稿回答 Q6 §8 checklist 的 8/10 题

### Day 2（周二）— KVCacheManager 深读
- **教案**：Q7-A — `KVCacheManager.allocate_slots()` 完整 trace（我会写）
- **重点源码**：[`vllm/v1/core/kv_cache_manager.py`](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/kv_cache_manager.py)
- **OS 配对**：Linux `__alloc_pages_nodemask` 的回退/eviction 逻辑
- **实验**：用 cuda-gdb 在 `allocate_slots` 上断点，跑一次推理看断点命中
- **交付**：`code-experiments/02_allocate_slots_trace.py` + gdb session log

### Day 3（周三）— Continuous Batching 教案（Q7 主菜）
- **教案**：Q7-B — Continuous Batching ↔ 协作式调度 / NIC 中断聚合（我会写）
- **重点源码**：[`vllm/v1/core/sched/scheduler.py`](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/sched/scheduler.py)
- **核心问题**：为什么不能用静态 batch？`waiting / running / preempted` 三个队列怎么转换？
- **OS 配对**：Linux CFS 的 vruntime / 协程调度器
- **交付**：dialogues/04-Q7-continuous-batching.md（我写）

### Day 4（周四）— Prefill vs Decode 失衡（Q8 教案）
- **教案**：Q8 — 为什么 prefill 是 compute-bound、decode 是 memory-bound（我会写）
- **核心数据**：算 1 个 token 的 FLOPs vs 加载它需要的 KV bytes，得到 arithmetic intensity
- **vLLM 怎么解**：chunked prefill + continuous batching 把两类请求混在一个 batch
- **重点源码**：scheduler 里的 `schedule()` 主循环 + chunked prefill 逻辑
- **OS 配对**：CPU-bound 进程 vs IO-bound 进程的混合调度（Linux IO scheduler 思路）
- **交付**：dialogues/05-Q8-prefill-decode-imbalance.md

### Day 5（周五）— Week 1 整合 + 自测
- **早**：把本周 4 个教案串起来画一张"请求生命周期"流程图（手画 / mermaid 都行）
- **下午**：模拟面试——我扮演面试官，连问 30 分钟
- **晚**：复盘哪些题答得不顺，回头补
- **交付**：`learning-journal/notes/week1-request-lifecycle.md`（你写，我审）

**Week 1 验收标准**：
- [ ] 能脱稿讲清楚 KV cache 为什么要分页
- [ ] 能在源码里 30 秒内指出 BlockPool / KVCacheManager / Scheduler 的位置和职责
- [ ] 能解释 prefill 和 decode 的本质区别和合批策略
- [ ] 能用 Linux mm / 协作式调度做类比讲解
- [ ] 跑通 3 个动手实验

---

## Week 2 — Attention 后端 + GPU 内存层级

> **本周目标**：理解 vLLM 怎么"接入"FlashAttention/xFormers 等不同 attention 实现；理解 GPU 上 KV 真实存储位置（HBM vs SRAM vs L2）。

### Day 6（周一）— GPU 内存层级补课（系统原理日）
- **教案**：Q9 — GPU memory hierarchy（HBM / L2 / SMEM / Registers）+ Roofline 模型（我写）
- **OS 配对**：CPU 的 RAM / L3 / L2 / L1 / Register 同构
- **关键数字**：你的 PRO 6000：HBM bandwidth ≈ ? GB/s vs SMEM bandwidth ≈ ? TB/s
- **实验**：用 `ncu` 跑一个简单 kernel，读 HBM 命中率
- **交付**：dialogues/06-Q9-gpu-memory-hierarchy.md

### Day 7（周二）— FlashAttention 原理
- **教案**：Q10 — FlashAttention 怎么避免把 N×N attention matrix 写回 HBM（我写）
- **关键洞察**：tiling + online softmax 让中间结果留在 SMEM
- **OS 配对**：流式处理 / 不写中间临时文件（streaming aggregation）
- **重点源码**：vllm-flash-attn 子模块 + [`vllm/v1/attention/backends/flash_attn.py`](file:///home/xuefeiz2/3rd/vllm/vllm/v1/attention/backends/) （路径可能略不同，当天确认）
- **交付**：dialogues/07-Q10-flash-attention.md

### Day 8（周三）— vLLM Attention Backend 抽象层
- **重点源码**：`vllm/v1/attention/backends/abstract.py` + 各个具体 backend
- **核心问题**：vLLM 怎么在 FA / xFormers / Triton / 默认实现 之间切换？为什么需要这层抽象？
- **OS 配对**：Linux VFS（虚拟文件系统）抽象不同文件系统
- **实验**：在你的机器上 trace 当前用的是哪个 backend，怎么选出来的
- **交付**：dialogues/08-attention-backend-abstraction.md（你写，我审）

### Day 9（周四）— PagedAttention CUDA Kernel 阅读
- **重点源码**：[`csrc/attention/paged_attention_v1.cu`](file:///home/xuefeiz2/3rd/vllm/csrc/attention/paged_attention_v1.cu) + v2
- **核心问题**：thread block 怎么用 block_table gather 出 KV？warp-level 协作怎么算 softmax？
- **OS 配对**：DMA scatter-gather（你之前写驱动应该熟）
- **难度警告**：CUDA 不熟没关系，目标是**读懂数据流向，不要求自己改 kernel**
- **交付**：在源码里加注释（fork 一个 branch），写一份"数据流图"

### Day 10（周五）— Week 2 整合 + 解决 vllm-flash-attn sm_80 问题
- **早**：诊断之前发现的 FA 子模块编译成 sm_80 的问题，确认 Blackwell 上是否真能跑
- **下午**：模拟面试 30 分钟（聚焦 attention + GPU memory）
- **晚**：写 week2-attention-stack.md
- **交付**：FA 问题诊断报告 + week2 总结

**Week 2 验收标准**：
- [ ] 能讲清楚 GPU memory hierarchy 各层带宽差距和对算法设计的影响
- [ ] 能解释 FlashAttention 的核心 trick
- [ ] 能讲清楚 vLLM 为什么需要 backend 抽象层
- [ ] 读懂 paged_attention CUDA kernel 的数据流（不要求会写）

---

## Week 3 — CUDA Kernel 实操 + 分布式基础

> **本周目标**：能改一个简单 CUDA kernel 并跑通；理解 TP/PP 的基本原理（不要求精通）。

### Day 11（周一）— CUDA 入门加速课
- **教案**：Q11 — CUDA 编程模型最小子集（grid/block/thread/warp/SMEM/全局同步）
- **OS 配对**：进程/线程/SIMD 类比
- **实验**：自己写一个向量加法 kernel，用 nsys profile

### Day 12（周二）— 改一个 vLLM 真实小 kernel
- **任务**：在 csrc 里挑一个简单 op（比如 RMSNorm），加一行 printf 调试输出，重编译，跑通
- **目的**：跑通"改 csrc → 重编译 → 测试"的反馈环路
- **耗时**：增量编译应该 5-10 min（不是全编 2 小时）

### Day 13（周三）— 分布式入门：Tensor Parallel
- **教案**：Q12 — TP 怎么把 attention head 切到多卡 + AllReduce 通信（我写）
- **OS 配对**：MPI / 分布式锁 / 一致性
- **重点源码**：[`vllm/distributed/`](file:///home/xuefeiz2/3rd/vllm/vllm/distributed/)
- **你的现实**：单卡用户，TP 需要理解原理但不需要跑通

### Day 14（周四）— Pipeline Parallel + 多卡通信原语
- **核心**：NCCL / SendRecv / AllGather 在 vLLM 里哪里被调用
- **不深入**：你单卡为主，目标是面试能讲、看源码不蒙

### Day 15（周五）— 选 PR 方向（关键决策日）
- **任务**：从 `notes/architecture-map.md` 里 5 个 good-first-PR 候选区挑 1 个
- **候选回顾**：
  1. KV offload observability（CPU↔GPU 换出指标）
  2. Block allocator 诊断工具
  3. Scheduler 边缘场景测试
  4. IPC 健壮性
  5. Metrics / 可观测性
- **决策方法**：去 GitHub 看每个区域的 open issue + recent PR，看哪个有人需要、哪个对应 issue 还没人接
- **交付**：`learning-journal/plan/pr-target.md` — 选定的方向 + 1 个具体 issue 链接

**Week 3 验收标准**：
- [ ] 能跑通 csrc 的增量改+编译+测试循环
- [ ] 能讲清楚 TP/PP 基本原理
- [ ] 选定 PR 方向 + 找到一个真实 issue

---

## Week 4 — 实操 PR

> **本周目标**：把 Day 15 选定的 issue 做出来，提 PR，进入 review。

### Day 16（周一）— Issue 深读 + 设计
- 读相关源码、相关 PR、相关 issue 讨论
- 写 design doc：你打算怎么改、为什么这么改、影响哪些测试
- **要求**：design doc 先发我（或先在 issue 评论里和 maintainer 对齐），**不要直接动代码**
- **交付**：`learning-journal/plan/pr-design.md`

### Day 17-19（周二-周四）— 实现
- 写代码 + 单元测试
- 严格按 [AGENTS.md](file:///home/xuefeiz2/3rd/vllm/AGENTS.md) 走：用 `uv` + `.venv`，跑 `pre-commit`，跑相关 pytest
- **每天结束**：commit + 推到自己 fork 的分支
- **不允许**：跳过 hook、跳过测试、用 `--no-verify`

### Day 20（周五）— PR 发出去
- 跑完整 test suite
- 写 PR 描述（按 AGENTS.md 要求：为什么不重复、跑了什么测试、声明 AI 辅助）
- 发出 PR，回到 issue 评论里 ping 相关 maintainer

### Day 21-22（周一-周二）— 应对 review
- maintainer 提的每个问题都要 (a) 理解 (b) 修 (c) 回复
- 这是**最有价值的学习环节**——真实代码标准、真实人的眼光

**Week 4 验收标准**：
- [ ] PR 发出
- [ ] 至少进入 review 状态（哪怕没 merge，也要有 maintainer 评论）
- [ ] 你能为这个 PR 的每一行变更辩护

---

## Buffer Days 23-30 — Review 来回 + 面试准备

剩余 8 天用来：
1. **PR review 来回**（maintainer 不一定及时，所以留 buffer）
2. **复习薄弱单元**（自测时哪个 checklist 没全过，回头补）
3. **面试演练**：我会用真实 LLM 推理岗常见问题面你 3-5 轮
4. **整理简历素材**：把 30 天产出整理成 1 段简历描述 + 3 条 STAR 故事

---

## 每日固定动作

| 时段 | 动作 | 时长 |
|---|---|---|
| 09:00-09:15 | 看昨天的 reflection，回忆昨天学了什么 | 15 min |
| 09:15-12:00 | 当日教案/源码阅读 | 2.75 h |
| 13:30-16:30 | 当日动手实验 | 3 h |
| 16:30-17:00 | 写 reflection 到 dialogues/ | 30 min |
| 17:00-18:00 | 自由探索 / 答疑 / 提问给我 | 1 h |

**周日休息或追进度**。不强制，但**强烈建议每周留 1 天完全 off**——这是马拉松不是 sprint。

---

## 反作弊规则（防止你 30 天后能讲不能做）

1. **每个教案对应至少 1 个动手实验**——只读不做不算学到
2. **每周一次模拟面试**——我会无情拷打，答不上来回去补
3. **PR 必须自己写每一行**——AI 可以辅助理解，不能代笔（AGENTS.md 明确禁止）
4. **所有 reflection 必须用自己的话**——不能复述教案，要写"我之前以为 X，现在发现 Y"

---

## 风险与应对

| 风险 | 应对 |
|---|---|
| 进度拖慢（某天某周没完成） | 优先砍"扩展阅读"，保留教案+实验+reflection 三件套 |
| Week 4 找不到合适 issue | 退回 Week 3 候选区，挑"加一个测试用例"或"加一段文档"这种最低门槛的 |
| Week 2 CUDA 啃不动 | 跳过 Day 9 自己改 kernel 的部分，只读懂 + 加注释即可 |
| PR review 太慢卡住 | 不影响后续，buffer 期间继续推进，PR 异步等 |
| 你发现某个方向特别感兴趣（比如 attention 优化） | 鼓励偏离计划深入，但要重写后续教案 |

---

## 不在这个计划里（明确不学的）

为了避免散光，**这 30 天明确不碰**以下内容：

- ❌ 训练（这是 serving，不是 training）
- ❌ Triton 编译器内部
- ❌ TPU/AMD 后端
- ❌ Speculative decoding 深入实现
- ❌ MoE 模型特殊优化
- ❌ 量化（GPTQ/AWQ）实现细节
- ❌ V0 引擎（已 deprecated）

这些以后想学随时回来。**先把核心路径打通**。

---

## 30 天后你应该能做到

- ✅ 在面试中讲出"我深度研究并贡献了 vLLM 的 [子系统]"，且能脱稿回答 30 分钟追问
- ✅ 在 vLLM 仓库有 1 个 merged 或 in-review 的 PR
- ✅ 看到任何 LLM serving 系统（SGLang / TensorRT-LLM）能快速类比理解
- ✅ 能独立诊断"为什么我的推理慢"这类性能问题
- ✅ 写在简历上的不再是"熟悉 LLM 推理"，而是"contributed to vLLM (PR #xxxx); deep working knowledge of PagedAttention, continuous batching, attention backends"

---

## 现在的状态

- ✅ Week 1 Day 1 = 今天，Q6 教案已就位
- ⏳ Week 1 Day 2 教案待写（KVCacheManager 深读）
- ⏳ Week 1 Day 3 教案待写（Continuous Batching）
- ⏳ Week 1 Day 4 教案待写（Prefill vs Decode）

**你给我反馈 Q6 教案合不合胃口**（讲法、深度、节奏），我就开始写 Day 2/3/4 的教案。
