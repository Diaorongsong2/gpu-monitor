#!/bin/bash
# vLLM OpenAI 兼容 API 服务 —— 在单张 GTX 1650 (4GB) 上跑 Qwen2.5-0.5B-Instruct
#
# 实测环境：Ubuntu 22.04 + NVIDIA Driver 595.97 + CUDA 13.2 + vLLM 0.18.0
# 说明：GTX 1650 不支持 bfloat16，vLLM 会自动回落到 float16（启动日志里会有 WARNING，属正常）
set -e

source vllm-env/bin/activate

python3 -m vllm.entrypoints.openai.api_server \
  --model Qwen/Qwen2.5-0.5B-Instruct \
  --host 0.0.0.0 \
  --port 8000 \
  --gpu-memory-utilization 0.7 \
  --max-model-len 1024 \
  --enforce-eager

# 关于几个参数：
#   --gpu-memory-utilization 0.7   显存只用 70%，留出余量给 Xorg / 桌面进程，
#                                  4GB 卡上开太高容易 OOM
#   --max-model-len 1024           KV Cache 上限，卡小就压低，这是省显存最有效的一项
#   --enforce-eager                关闭 CUDA Graph 捕获，少占显存、启动更快；
#                                  代价是吞吐略降，单卡小规模用影响不大
#
# 启动完成后验证：
#   curl http://localhost:8000/v1/models
#   curl http://localhost:8000/v1/chat/completions \
#     -H "Content-Type: application/json" \
#     -d '{"model":"Qwen/Qwen2.5-0.5B-Instruct",
#          "messages":[{"role":"user","content":"你好"}],
#          "max_tokens":64}'
