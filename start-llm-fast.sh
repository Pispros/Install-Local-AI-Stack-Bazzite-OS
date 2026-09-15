#!/bin/bash
# Serveur FIM (autocompletion) : DeepSeek-Coder-V2-Lite (Q5_K_M)
# Optimisé pour Radeon 780M (Vulkan/RADV) - Contexte 16384
# Port: 8081
# Tous les chemins dérivent de $HOME → aucun chemin machine en dur.

export AMD_VULKAN_ICD=RADV
export RADV_PERFTEST=gpl
export RADV_DEBUG=zerovram
export GGML_VK_ALLOW_SYSMEM_FALLBACK=1
export MESA_SHADER_CACHE_DIR="$HOME/.cache/mesa_shader_cache"
export MESA_SHADER_CACHE_MAX_SIZE="4G"
export OMP_NUM_THREADS=4
export GOMP_CPU_AFFINITY="8-11"
mkdir -p "$MESA_SHADER_CACHE_DIR"

LLAMA_DIR="$HOME/llama.cpp/build"

echo "Démarrage du serveur DeepSeek-Coder-V2-Lite (Q5_K_M) sur port 8081..."
exec "$LLAMA_DIR/bin/llama-server" \
  -hf bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF:Q5_K_M \
  --alias deepseek-coder-q5 \
  -ngl 99 \
  --ctx-size 16384 \
  --parallel 1 \
  -fa on \
  --cache-reuse 256 \
  -b 2048 -ub 2048 \
  --threads 4 --threads-batch 4 \
  --no-warmup \
  --host 0.0.0.0 --port 8081 \
  --temp 0.1 --top-p 0.9 \
  --top-k 40 \
  --repeat-penalty 1.1
