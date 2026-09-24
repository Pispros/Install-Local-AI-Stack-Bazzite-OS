#!/bin/bash
# Serveur FIM (autocomplétion) : Qwen2.5-Coder-3B (base, Q5_K_M) — supporte les tokens FIM.
# Optimisé pour Radeon 780M (Vulkan/RADV) - Contexte 16384
# Port: 8081
# -hf télécharge automatiquement le modèle s'il est absent du cache (download-if-missing natif).
#
# ── FIX MÉMOIRE : --load-mode none (ancien --no-mmap, supprimé des builds récents). ──
#   Même raison que le serveur chat : sur le 780M la "VRAM" = RAM, et mmap fait
#   compter le modèle 2x. Petit modèle (~2.5 Go) donc impact modeste ici, mais on
#   uniformise pour ne pas gaspiller de RAM quand les deux serveurs tournent ensemble.

export AMD_VULKAN_ICD=RADV
export RADV_PERFTEST=gpl
export RADV_DEBUG=zerovram
export GGML_VK_ALLOW_SYSMEM_FALLBACK=1
export MESA_SHADER_CACHE_DIR="$HOME/.cache/mesa_shader_cache"
export MESA_SHADER_CACHE_MAX_SIZE="4G"
export OMP_NUM_THREADS=4
export GOMP_CPU_AFFINITY="8-11"
mkdir -p "$MESA_SHADER_CACHE_DIR"

echo "Démarrage du serveur Qwen2.5-Coder-3B (Q5_K_M) sur port 8081..."

exec /home/NJMER/llama.cpp/build/bin/llama-server \
  -hf bartowski/Qwen2.5-Coder-3B-GGUF:Q5_K_M \
  --alias qwen2.5-coder-3b \
  -ngl 99 \
  --load-mode none \
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
