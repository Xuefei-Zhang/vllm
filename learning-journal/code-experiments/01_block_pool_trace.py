"""
Q6 实验 1：观察 vLLM 给你分配多少 block。
跑法：.venv/bin/python learning-journal/code-experiments/01_block_pool_trace.py
"""

from vllm.v1.core.block_pool import BlockPool

pool = BlockPool(
    num_gpu_blocks=100,  # 假装 GPU 只有 100 个 block
    enable_caching=False,
)

print(f"初始空闲 block 数: {pool.get_num_free_blocks()}")
print(f"  (注意：block_id=0 被预留为 null_block，所以实际可分配 99)")
print()

# 用户 A：要 10 个 block (160 token)
blocks_A = pool.get_new_blocks(10)
print(f"分配给 A 的 block_id: {[b.block_id for b in blocks_A]}")
print(f"剩余空闲: {pool.get_num_free_blocks()}")
print()

# 用户 B：要 5 个
blocks_B = pool.get_new_blocks(5)
print(f"分配给 B 的 block_id: {[b.block_id for b in blocks_B]}")
print(f"剩余空闲: {pool.get_num_free_blocks()}")
print()

# A 用完释放
pool.free_blocks(blocks_A)
print(f"A 释放后空闲: {pool.get_num_free_blocks()}")
print(f"  (释放的 block 挂回 free_block_queue 末尾，将被 LRU 优先复用)")
print()

# B 又申请 3 个 → 复用 A 释放的 block
blocks_B2 = pool.get_new_blocks(3)
print(f"B 第二次拿到的 block_id: {[b.block_id for b in blocks_B2]}")
print()
print("观察点：")
print("  - B 第二次拿到的 block_id 是不是 A 之前用过的？")
print("  - 这就是'物理 frame 被复用'，等价于 OS 进程退出后页框被新进程占用。")
print()
print(f"最终空闲: {pool.get_num_free_blocks()}")
