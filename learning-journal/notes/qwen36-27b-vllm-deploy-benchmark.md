# Qwen3.6-27B on vLLM — Deploy & Benchmark

## Environment

- Date: 2026-05-07
- Repo: vllm-project/vllm @ local fork (`027527f31`, vLLM `0.20.2rc1.dev42+g98661fe01`)
- Python: 3.12 (`.venv`)
- torch: `2.11.0+cu130`
- CUDA available: True
- GPU: NVIDIA RTX PRO 6000 Blackwell Workstation Edition (1x)
- Model path: `/home/xuefeiz2/models/Qwen3.6-27B`
- Architecture (resolved by vLLM): `Qwen3_5ForConditionalGeneration` (hybrid attention + Mamba)

## Server Command

```bash
.venv/bin/python -m vllm.entrypoints.openai.api_server \
  --model /home/xuefeiz2/models/Qwen3.6-27B \
  --served-model-name qwen3.6-27b \
  --host 0.0.0.0 \
  --port 8000 \
  --trust-remote-code \
  --tensor-parallel-size 1 \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.90 \
  --max-num-seqs 512
```

Notes:

- Default `max_num_seqs=1024` failed with
  `ValueError: max_num_seqs (1024) exceeds available Mamba cache blocks (615)`.
  Lowering to `512` unblocks CUDA graph capture for this hybrid (Mamba) model.
- `VLLM_USE_V1=1` is no longer recognized (V1 engine is the default).

Server load result:

- Model loading: 51.08 GiB, ~34s
- KV cache memory: 29.47 GiB
- GPU KV cache size: 359,862 tokens (max concurrency for 8k ctx ≈ 43.93x)

## Smoke Test

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6-27b",
    "messages": [{"role": "user", "content": "用一句话解释 vLLM。"}],
    "max_tokens": 512
  }' | jq -r '.choices[0].message.content'
```

- `/v1/models`: pass
- `/v1/chat/completions`: pass
- 注意：模型默认输出包含「思考过程」结构。`max_tokens=64` 时只能拿到 reasoning 开头被截断（`finish_reason=length`）。Smoke test 用 `>=512`。

## Benchmark Command Pattern

`benchmarks/benchmark_serving.py` 已废弃，改用 vLLM CLI：

```bash
.venv/bin/vllm bench serve \
  --backend openai-chat \
  --base-url http://localhost:8000 \
  --endpoint /v1/chat/completions \
  --model qwen3.6-27b \
  --tokenizer /home/xuefeiz2/models/Qwen3.6-27B \
  --dataset-name random \
  --num-prompts <N> \
  --random-input-len <IN> \
  --random-output-len <OUT> \
  --request-rate <R|inf> \
  --save-result \
  --result-dir bench_results \
  --result-filename <name>.json
```

Tip: `--model` 必须等于 server 的 served-model-name（用于 OpenAI 请求）；`--tokenizer` 给本地路径，避免去 HF 拉 `qwen3.6-27b/config.json` 报 401/404。

## Results (3 cases)

| Metric | A: 1024/128, inf, 100 reqs | B: 2048/256, inf, 200 reqs | rate8: 1024/128, 8 RPS, 200 reqs |
|---|---:|---:|---:|
| Successful / Failed | 100 / 0 | 200 / 0 | 200 / 0 |
| Duration (s) | 24.19 | 100.15 | 51.71 |
| Total input tokens | 103,438 | 411,683 | 206,883 |
| Total generated tokens | 12,800 | 51,200 | 25,600 |
| Request throughput (req/s) | 4.13 | 2.00 | 3.87 |
| **Output tok/s (avg)** | **529** | **511** | **495** |
| **Peak output tok/s** | **1,600** | **1,620** | **1,796** |
| Total tok/s (in+out) | 4,805 | 4,622 | 4,496 |
| Peak concurrent | 100 | 200 | 200 |
| Mean TTFT (ms) | 9,392 | 41,623 | 8,719 |
| Median TTFT (ms) | 9,644 | 34,001 | 6,111 |
| P99 TTFT (ms) | 16,285 | 83,739 | 20,244 |
| Mean TPOT (ms) | 114 | 162 | 181 |
| Median TPOT (ms) | 113 | 192 | 209 |
| P99 TPOT (ms) | 167 | 201 | 243 |
| Median ITL (ms) | 64 | 68 | 76 |
| P99 ITL (ms) | 1,261 | 1,401 | 1,326 |

Raw JSON: [`bench_results/qwen36_27b_A.json`](../../bench_results/qwen36_27b_A.json),
[`bench_results/qwen36_27b_B.json`](../../bench_results/qwen36_27b_B.json),
[`bench_results/qwen36_27b_rate8.json`](../../bench_results/qwen36_27b_rate8.json)

## Observations

1. **稳态 output throughput ~500 tok/s，峰值 1.6k–1.8k tok/s**
   三组负载完全不同（小输入/大输入/限速），平均 output 都卡在 ~500，说明这是单卡 RTX PRO 6000 + Qwen3.6-27B 的稳态 decode 上限。但 peak 能到 1.6k+，说明瞬时算力远高于平均，prefill 阶段会偷走 GPU。

2. **B 的 TTFT mean 飙到 41.6s ≠ 模型变慢**
   200 条 2048-token 请求一次涌进，prefill 必须排队，最后一条自然 TTFT 接近 1 分钟。Total throughput 只比 A 掉 4%，说明 GPU 没空着，是调度排队的代价。

3. **rate8 验证「TTFT 高 ≠ 模型慢」**
   rate8 输入和 A 一样（1024/128），但限速 8 RPS，TTFT median 从 9.6s → 6.1s。Output throughput 仅下降 6%，说明 rate=8 GPU 仍未压满。这才是面向真实用户的体感。

4. **TPOT 随并发线性上升，是 continuous batching 的代价**
   peak concurrent 100 → 200 时，TPOT mean 从 114ms 涨到 162–181ms，但 total throughput 几乎不变 → 牺牲单条延迟换总吞吐，正是 vLLM 的核心权衡。

5. **ITL P99 1.2–1.4s 的偶发停顿**
   中位 ITL 64–76ms（流畅），但 P99 飙到 1.2s 以上。来自新请求加入 batch、prefill chunk 抢 step、偶发 CUDA graph 切换。对话场景无感，但实时（TTS 同步等）需要关注。

## Open Questions

- Qwen3.6 这个 hybrid attention + Mamba 架构里，Mamba cache block 是怎么和 attention KV cache 协调的？为什么默认 `max_num_seqs=1024` 会撞 615 上限？
- `Peak output tok/s ≈ 3 × avg output tok/s` 的差距，主要被 prefill 偷走了多少？是否值得用 `--enable-chunked-prefill` 调度调优？
- 单卡 27B 在 BF16 下，weight 51 GiB 已经接近显存瓶颈；如果上 FP8 / INT8 量化，KV cache 能再吃多少 token、throughput 能提多少？

## Problems / Fixes

| 时间 | 问题 | 根因 | 修复 |
|---|---|---|---|
| 14:43 | `max_num_seqs (1024) exceeds available Mamba cache blocks (615)` | hybrid Mamba 模型默认 max_num_seqs 与可用 cache 不匹配 | `--max-num-seqs 512` |
| 15:04 | `model ''` 启动失败 | shell 没设 `MODEL` 变量，`$MODEL` 展开成空 | 直接用绝对路径或先 `export MODEL=...` |
| 15:28 | curl 看到的「全是 metadata」 | smoke test `max_tokens=64` 太小，模型刚开始 reasoning 就被截断 | `max_tokens >= 512`，并用 `jq -r '.choices[0].message.content'` 抽答案 |
| 15:52 | `benchmark_serving.py` 报 deprecated | 脚本已迁到 CLI | 改用 `vllm bench serve` |
| 15:59 | `OSError: qwen3.6-27b is not a local folder` | bench 客户端拿 served-model-name 去本地/HF 加载 tokenizer 失败（HF mirror 还 401） | 加 `--tokenizer /home/xuefeiz2/models/Qwen3.6-27B` |
