"""
Q7-A 实验：trace KVCacheManager.allocate_slots() 完整路径。
不启动 GPU，只用 BlockPool + KVCacheManager 模拟分配。

注意：v1 KVCacheManager 需要完整的 KVCacheConfig 才能初始化，
所以这个脚本演示的是核心逻辑而非完整 KVCacheManager 实例化。
真实流程见 vllm/v1/core/kv_cache_manager.py:225 (allocate_slots)。

跑法：.venv/bin/python learning-journal/code-experiments/02_allocate_slots_trace.py
"""

from vllm.v1.core.block_pool import BlockPool

print("=" * 60)
print("模拟 allocate_slots 的核心逻辑：按 block_size 切片分配")
print("=" * 60)

BLOCK_SIZE = 16  # vLLM 默认每 block 16 token

pool = BlockPool(num_gpu_blocks=50, enable_caching=True)

# 模拟"请求 R1 来了，prompt 35 token"
prompt_len = 35
num_blocks_needed = (prompt_len + BLOCK_SIZE - 1) // BLOCK_SIZE
print(f"\nR1 prompt = {prompt_len} token → 需要 {num_blocks_needed} 个 block")
print(f"  ({num_blocks_needed - 1} 个满 + 1 个半满，最后 block 浪费 "
      f"{num_blocks_needed * BLOCK_SIZE - prompt_len} token 空间)")

blocks_R1 = pool.get_new_blocks(num_blocks_needed)
print(f"  分配 block_id: {[b.block_id for b in blocks_R1]}")

# 模拟"R1 生成了 20 个 token，需要更多 block"
gen_len = 20
total_len = prompt_len + gen_len
new_total_blocks = (total_len + BLOCK_SIZE - 1) // BLOCK_SIZE
extra_blocks_needed = new_total_blocks - num_blocks_needed
print(f"\nR1 生成 {gen_len} token (累计 {total_len}) → 还需 {extra_blocks_needed} 个 block")
if extra_blocks_needed > 0:
    extra_blocks = pool.get_new_blocks(extra_blocks_needed)
    print(f"  新分配 block_id: {[b.block_id for b in extra_blocks]}")
    blocks_R1 += extra_blocks

print(f"\nR1 现在共占 {len(blocks_R1)} 个 block，"
      f"逻辑序列 {total_len}/{len(blocks_R1) * BLOCK_SIZE} token (利用率 "
      f"{total_len / (len(blocks_R1) * BLOCK_SIZE):.0%})")

# 释放
pool.free_blocks(blocks_R1)
print(f"\nR1 完成 → 释放，当前空闲 block: {pool.get_num_free_blocks()}")

print("\n" + "=" * 60)
print("学习要点：")
print("  1. 分配以 block (16 token) 为单位，不是按 token 精细分配")
print("  2. 内部碎片仅在每个请求的'最后一个 block'，最多浪费 15 token")
print("  3. 没有外部碎片：只要总空闲 block 够，就能分配（不要求连续）")
print("  4. 释放即归还到 free_block_queue 末尾（LRU 顺序）")
print("=" * 60)
