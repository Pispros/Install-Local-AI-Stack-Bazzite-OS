#!/bin/bash
# Serveur CHAT : GLM-4.7-Flash (30B-A3B MoE, full-attention) sur Radeon 780M (Vulkan/RADV), port 8080

# --- Environnement Vulkan / RADV ---
export AMD_VULKAN_ICD=RADV
export RADV_PERFTEST=gpl
export RADV_DEBUG=zerovram
export GGML_VK_ALLOW_SYSMEM_FALLBACK=1
export MESA_SHADER_CACHE_DIR="$HOME/.cache/mesa_shader_cache"
export MESA_SHADER_CACHE_MAX_SIZE="4G"

# --- CPU ---
export OMP_NUM_THREADS=8
export GOMP_CPU_AFFINITY="0-7"

mkdir -p "$MESA_SHADER_CACHE_DIR"

exec /home/NJMER/llama.cpp/build/bin/llama-server \
  --hf-repo unsloth/GLM-4.7-Flash-GGUF \
  --hf-file GLM-4.7-Flash-UD-Q4_K_XL.gguf \
  --no-mmproj \
  --alias glm-4.7-flash \
  -ngl 99 \
  --ctx-size 105000 \
  --parallel 1 \
  -fa on \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  -b 2048 -ub 512 \
  --threads 8 --threads-batch 8 \
  --host 0.0.0.0 --port 8080 \
  --jinja \
  --reasoning-format deepseek \
  --temp 0.7 --top-p 0.95 --min-p 0.01 \
  --ui-mcp-proxy
