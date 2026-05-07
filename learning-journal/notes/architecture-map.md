# vLLM Architecture Map

> Generated for: a senior C/C++ systems/driver engineer transitioning into LLM inference engine core development.
> Difficulty tier: **E** = Easy (familiar systems work), **M** = Medium, **H** = Hard (needs ML/CUDA depth).

---

## 1. Entry Points (CLI, OpenAI-compat API server) — Tier: **E**

- [llm.py](file:///home/xuefeiz2/3rd/vllm/vllm/entrypoints/llm.py) — generic CLI entry / programmatic LLM class
- [api_server.py](file:///home/xuefeiz2/3rd/vllm/vllm/entrypoints/api_server.py) — minimal HTTP server helpers
- [openai/engine/serving.py](file:///home/xuefeiz2/3rd/vllm/vllm/entrypoints/openai/engine/serving.py) — OpenAI-compat server (the production path)
- [cli/launch.py](file:///home/xuefeiz2/3rd/vllm/vllm/entrypoints/cli/launch.py) — `vllm serve` CLI wiring

**Role**: Parse user input (CLI args / HTTP), validate OpenAI-style payloads, convert to internal request objects, hand off to LLMEngine.

---

## 2. LLMEngine / AsyncLLMEngine — Tier: **M**

- [v1/engine/llm_engine.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/engine/llm_engine.py) — **V1 engine (study this first)**
- [v1/engine/core.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/engine/core.py) — V1 orchestration loop
- [v1/engine/output_processor.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/engine/output_processor.py) — token streaming / sampling handoff
- [engine/llm_engine.py](file:///home/xuefeiz2/3rd/vllm/vllm/engine/llm_engine.py) — legacy V0 (read for historical context only)

**V0 vs V1**: V1 is the active redesign — modular scheduler, cleaner attention backend selection, better KV offload. V0 is the older monolithic design. **Always study V1 first.**

**Role**: Orchestrate request lifecycle, register with scheduler, coordinate prefill/decode cycles, manage state.

---

## 3. Scheduler (Continuous Batching) — Tier: **M** ⭐ Sweet spot for systems engineers

- [v1/core/sched/scheduler.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/sched/scheduler.py) — main scheduler
- [v1/core/sched/request_queue.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/sched/request_queue.py) — priority queue
- [v1/core/sched/output.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/sched/output.py) — token emission coordination
- [v1/core/sched/interface.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/sched/interface.py) — plugin interface
- [config/scheduler.py](file:///home/xuefeiz2/3rd/vllm/vllm/config/scheduler.py) — tunables

**Role**: Continuous batching — aggregate partial requests into prefill/decode batches, enforce priorities, support preemption. **This is where your FreeRTOS scheduling intuition transfers most directly.**

---

## 4. KV Cache / Block Manager (PagedAttention) — Tier: **H**

- [csrc/attention/paged_attention_v1.cu](file:///home/xuefeiz2/3rd/vllm/csrc/attention/paged_attention_v1.cu) — CUDA paged attention v1
- [csrc/attention/paged_attention_v2.cu](file:///home/xuefeiz2/3rd/vllm/csrc/attention/paged_attention_v2.cu) — CUDA paged attention v2
- [csrc/cache.h](file:///home/xuefeiz2/3rd/vllm/csrc/cache.h) — cache data structures
- [v1/attention/ops/paged_attn.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/attention/ops/paged_attn.py) — Python op layer
- [v1/kv_offload/base.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/kv_offload/base.py) — offload policy
- [v1/kv_offload/cpu/gpu_worker.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/kv_offload/cpu/gpu_worker.py) — CPU↔GPU page transfers

**Role**: Manage KV state via paged allocator (like OS virtual memory for attention!), support CPU offload for long contexts. **The block-table-as-page-table analogy is the single most important concept to internalize.**

---

## 5. Model Executor / Worker — Tier: **M-H**

- [v1/worker/gpu_model_runner.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/worker/gpu_model_runner.py) — GPU model runner
- [model_executor/parameter.py](file:///home/xuefeiz2/3rd/vllm/vllm/model_executor/parameter.py) — parameter metadata
- [model_executor/models/__init__.py](file:///home/xuefeiz2/3rd/vllm/vllm/model_executor/models/__init__.py) — model registry
- [distributed/parallel_state.py](file:///home/xuefeiz2/3rd/vllm/vllm/distributed/parallel_state.py) — TP/PP/EP coordination

**Role**: Load (possibly sharded) weights, execute forward passes for prefill/decode, coordinate distributed collectives.

---

## 6. Attention Backends — Tier: **H**

- [v1/attention/selector.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/attention/selector.py) — backend dispatch logic
- [v1/attention/backends/flash_attn.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/attention/backends/flash_attn.py) — FlashAttention
- [v1/attention/backends/triton_attn.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/attention/backends/triton_attn.py) — Triton kernels
- [vllm_flash_attn/flash_attn_interface.py](file:///home/xuefeiz2/3rd/vllm/vllm/vllm_flash_attn/flash_attn_interface.py) — C++/CUDA bindings

**Role**: Pick optimal attention kernel per device/model (SM version, dtype, sequence shape).

---

## 7. C++/CUDA Layer (csrc/) — Tier: **H**

- [csrc/attention/](file:///home/xuefeiz2/3rd/vllm/csrc/attention/) — attention kernels
- [csrc/moe/](file:///home/xuefeiz2/3rd/vllm/csrc/moe/) — MoE kernels (permute / grouped GEMM)
- [csrc/topk.cu](file:///home/xuefeiz2/3rd/vllm/csrc/topk.cu) — sampling kernel
- [csrc/cutlass_extensions/](file:///home/xuefeiz2/3rd/vllm/csrc/cutlass_extensions/) — CUTLASS GEMM epilogues
- [csrc/cache.h](file:///home/xuefeiz2/3rd/vllm/csrc/cache.h) — cache ops

**Role**: Production CUDA kernels — thread-block scheduling, memory layouts, fusion.

---

## 8. Sampling / Logits Processors — Tier: **M**

- [v1/sample/sampler.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/sample/sampler.py) — sampling control loop
- [v1/sample/ops/topk_topp_sampler.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/sample/ops/topk_topp_sampler.py) — top-k/top-p
- [sampling_params.py](file:///home/xuefeiz2/3rd/vllm/vllm/sampling_params.py) — params
- [beam_search.py](file:///home/xuefeiz2/3rd/vllm/vllm/beam_search.py) — beam search

---

## 9. torch.compile / CUDA Graphs — Tier: **H**

- [vllm/compilation/](file:///home/xuefeiz2/3rd/vllm/vllm/compilation/) — compile passes & cache
- [tests/compile/fullgraph/test_full_cudagraph.py](file:///home/xuefeiz2/3rd/vllm/tests/compile/fullgraph/test_full_cudagraph.py) — graph capture tests

**Role**: Build/cache compiled execution graphs to amortize Python overhead per token.

---

## 10. Distributed / Parallelism — Tier: **H**

- [distributed/parallel_state.py](file:///home/xuefeiz2/3rd/vllm/vllm/distributed/parallel_state.py) — global state
- [distributed/device_communicators/](file:///home/xuefeiz2/3rd/vllm/vllm/distributed/device_communicators/) — NCCL / SHM / CPU communicators
- [distributed/kv_transfer/](file:///home/xuefeiz2/3rd/vllm/vllm/distributed/kv_transfer/) — KV transfer
- [model_executor/layers/fused_moe/](file:///home/xuefeiz2/3rd/vllm/vllm/model_executor/layers/fused_moe/) — MoE all-to-all

---

## 11. Quantization — Tier: **H**

- [config/quantization.py](file:///home/xuefeiz2/3rd/vllm/vllm/config/quantization.py) — config
- [model_executor/layers/quantization/](file:///home/xuefeiz2/3rd/vllm/vllm/model_executor/layers/quantization/) — formats / loaders

---

## 12. Multi-modal — Tier: **M** (low priority for systems track)

- [multimodal/](file:///home/xuefeiz2/3rd/vllm/vllm/multimodal/)
- model_executor/models/*_vl.py

---

## 🎯 Good First PR Targets (low ML knowledge required)

1. **KV offload worker observability** — [v1/kv_offload/cpu/gpu_worker.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/kv_offload/cpu/gpu_worker.py): histograms/counters/queue-depth gauges
2. **Block allocator diagnostics** — [csrc/cache.h](file:///home/xuefeiz2/3rd/vllm/csrc/cache.h) + [paged_attn.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/attention/ops/paged_attn.py): opt-in block table dump
3. **Scheduler edge-case tests** — [scheduler.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/sched/scheduler.py) + [request_queue.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/core/sched/request_queue.py): priority inversion, preemption races
4. **IPC / communicator robustness** — [distributed/device_communicators/](file:///home/xuefeiz2/3rd/vllm/vllm/distributed/device_communicators/): timeouts, partial failure handling, buffer pooling
5. **Metrics improvements** — [v1/metrics/stats.py](file:///home/xuefeiz2/3rd/vllm/vllm/v1/metrics/stats.py): GPU/KV/block telemetry

---

## 📅 Suggested 30-Day Reading Order

| Week | Theme | Primary files |
|---|---|---|
| 1 | Entry → Engine | entrypoints/* → v1/engine/* |
| 2 | Scheduler | v1/core/sched/* |
| 3 | KV cache & PagedAttention | v1/attention/ops/paged_attn.py + csrc/attention/ + csrc/cache.h |
| 4 | Worker, attention backends, kernels | v1/worker/* + v1/attention/backends/* + compilation/ |
