export AMD_VULKAN_ICD=RADV
export RADV_PERFTEST=gpl
export RADV_DEBUG=zerovram
export GGML_VK_ALLOW_SYSMEM_FALLBACK=1
export MESA_SHADER_CACHE_DIR="$HOME/.cache/mesa_shader_cache"
export MESA_SHADER_CACHE_MAX_SIZE="4G"
export OMP_NUM_THREADS=8
export GOMP_CPU_AFFINITY="0-7"
mkdir -p "$MESA_SHADER_CACHE_DIR"
exec /home/NJMER/llama.cpp/build/bin/llama-server \
  --hf-repo unsloth/Qwen3-30B-A3B-GGUF \
  --hf-file Qwen3-30B-A3B-UD-Q4_K_XL.gguf \
  --no-mmproj \
  --alias qwen3-30b-a3b \
  -ngl 99 \
  --ctx-size 138240 \
  --parallel 1 \
  -fa on \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  -b 2048 -ub 1024 \
  --threads 8 --threads-batch 8 \
  --no-warmup \
  --host 0.0.0.0 --port 8080 \
  --jinja \
  --reasoning-format deepseek \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 \
  --webui-mcp-proxy
