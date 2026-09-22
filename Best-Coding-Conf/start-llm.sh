#!/bin/bash
# Serveur CHAT Qwen3-Coder-Next (MoE qwen3_next / Gated DeltaNet) — jail bubblewrap,
# imbriqué dans distrobox Fedora (podman rootless) / Bazzite.
# ⚠ Modèle TEXTE-ONLY (coder) : plus de mmproj / vision.
# DOWNLOAD-IF-MISSING via llama-server lui-même (-hf) : pas de CLI huggingface, pas de pip
#   (indispo sur Bazzite). Le jail ne fait PAS --unshare-net -> réseau du host dispo dedans,
#   donc le -hf télécharge directement. Le cache llama.cpp est redirigé vers $WORK_DIR
#   (seul chemin bind en écriture) via LLAMA_CACHE ; ~/.cache n'est pas monté dans le jail.
# MCP distant (searxng-mcp) branché via la WebUI : nécessite --ui-mcp-proxy (dernière ligne).
# ÉCRITURES : uniquement $WORK_DIR. LECTURES : $WORK_DIR (rw) + runtime ro.
# Nested podman : /proc bindé, pas d'unshare-pid → sinon "Can't mount proc: Operation not permitted".
set -euo pipefail

command -v bwrap >/dev/null || { echo "bwrap absent : sudo dnf install -y bubblewrap"; exit 1; }

export AMD_VULKAN_ICD=RADV
export RADV_PERFTEST=gpl
export RADV_DEBUG=zerovram
export GGML_VK_ALLOW_SYSMEM_FALLBACK=1
export OMP_NUM_THREADS=8
export GOMP_CPU_AFFINITY="0-7"

WORK_DIR="/home/NJMER/All/llm-working-dir"
SLOT_DIR="$WORK_DIR/.slots"
export MESA_SHADER_CACHE_DIR="$WORK_DIR/.mesa_cache"
export MESA_SHADER_CACHE_MAX_SIZE="4G"

# Cache des modèles téléchargés par llama-server (-hf). Doit être inscriptible ET bind dans le jail.
export LLAMA_CACHE="$WORK_DIR/.llama-cache"

mkdir -p "$WORK_DIR" "$SLOT_DIR" "$MESA_SHADER_CACHE_DIR" "$LLAMA_CACHE"

LLAMA_DIR="/home/NJMER/llama.cpp/build"                 # binaire + libs (ro)

# ── Modèle : Qwen3-Coder-Next, quant UD-Q4_K_XL (~40-42 Go). K-quant choisi exprès :
#    sur backend Vulkan (RADV), les i-quants (IQ4_XS) sont mal supportés et font planter
#    llama-server sur RDNA3 avec le template de chat complet -> on prend un K-quant.
#    llama-server le télécharge au 1er lancement dans $LLAMA_CACHE, puis le réutilise
#    (aucun download ensuite). ──
HF_MODEL="unsloth/Qwen3-Coder-Next-GGUF:UD-Q4_K_XL"

exec bwrap \
  --die-with-parent \
  --unshare-user \
  --new-session \
  --bind /proc /proc \
  --dev /dev --dev-bind /dev/dri /dev/dri \
  --ro-bind /sys /sys \
  --tmpfs /tmp \
  --ro-bind /usr /usr \
  --symlink usr/bin /bin \
  --symlink usr/sbin /sbin \
  --symlink usr/lib /lib \
  --symlink usr/lib64 /lib64 \
  --ro-bind /etc /etc \
  --ro-bind "$LLAMA_DIR" "$LLAMA_DIR" \
  --bind "$WORK_DIR" "$WORK_DIR" \
  --chdir "$WORK_DIR" \
  "$LLAMA_DIR/bin/llama-server" \
    -hf "$HF_MODEL" \
    --alias qwen3-coder-next \
    -ngl 99 \
    --ctx-size 131072 \
    --parallel 1 \
    --slot-save-path "$SLOT_DIR" \
    -fa on \
    --cache-type-k q8_0 --cache-type-v q8_0 \
    -b 1024 -ub 256 \
    --threads 8 --threads-batch 8 \
    --host 0.0.0.0 --port 8080 \
    --jinja \
    --tools read_file,write_file,edit_file,grep_search,file_glob_search,exec_shell_command \
    --cors-origins '*' \
    --temp 0.7 --top-p 0.8 --top-k 20 --min-p 0 \
    --ui-mcp-proxy \
    --ui-config-file "/home/NJMER/All/llm-working-dir/mcp.json"
