#!/bin/bash
# Serveur FIM (autocompletion) : Qwen2.5-Coder-1.5B base sur Radeon 780M (Vulkan/RADV), port 8081
export AMD_VULKAN_ICD=RADV
export RADV_PERFTEST=gpl
export RADV_DEBUG=zerovram
export GGML_VK_ALLOW_SYSMEM_FALLBACK=1
export MESA_SHADER_CACHE_DIR="$HOME/.cache/mesa_shader_cache"
export MESA_SHADER_CACHE_MAX_SIZE="4G"
export OMP_NUM_THREADS=4
export GOMP_CPU_AFFINITY="8-11"
mkdir -p "$MESA_SHADER_CACHE_DIR"

exec /home/NJMER/llama.cpp/build/bin/llama-server \
  -hf ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF \
  --alias qwen-coder-fim \
  -ngl 99 \
  --ctx-size 8192 \
  --parallel 1 \
  -fa on \
  --cache-reuse 256 \
  -b 1024 -ub 1024 \
  --threads 4 --threads-batch 4 \
  --no-warmup \
  --host 0.0.0.0 --port 8081 \
  --temp 0.1 --top-p 0.9
