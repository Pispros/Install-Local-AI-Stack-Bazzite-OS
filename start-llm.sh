#!/bin/bash
# Serveur CHAT+VISION Qwen3.5-35B-A3B — jail bubblewrap, imbriqué dans distrobox Fedora (podman rootless) / Bazzite.
# Fichiers LOCAUX depuis le cache huggingface_hub (pas de -hf, aucun download au lancement).
# MCP distant (searxng-mcp) branché via la WebUI : nécessite --ui-mcp-proxy (dernière ligne).
# ÉCRITURES : uniquement $WORK_DIR. LECTURES : $WORK_DIR (rw) + runtime ro + dossier du modèle (ro). Reste de $HOME invisible.
# Nested podman : /proc bindé, pas d'unshare-pid → sinon "Can't mount proc: Operation not permitted".
set -euo pipefail

command -v bwrap >/dev/null || { echo "bwrap absent : sudo dnf install -y bubblewrap"; exit 1; }

export AMD_VULKAN_ICD=RADV
export RADV_PERFTEST=gpl
export RADV_DEBUG=zerovram
export GGML_VK_ALLOW_SYSMEM_FALLBACK=1
export OMP_NUM_THREADS=8
export GOMP_CPU_AFFINITY="0-7"

WORK_DIR="/home/xxx/All/llm-working-dir"
SLOT_DIR="$WORK_DIR/.slots"
export MESA_SHADER_CACHE_DIR="$WORK_DIR/.mesa_cache"
export MESA_SHADER_CACHE_MAX_SIZE="4G"
mkdir -p "$WORK_DIR" "$SLOT_DIR" "$MESA_SHADER_CACHE_DIR"

LLAMA_DIR="/home/xxx/llama.cpp/build"                 # binaire + libs (ro)

# ── Fichiers dans le cache hub (on binde tout le dossier models--… pour que les symlinks snapshots→blobs résolvent) ──
HUB="$HOME/.cache/huggingface/hub/models--unsloth--Qwen3.5-35B-A3B-GGUF"
MODEL=$(ls "$HUB"/snapshots/*/Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf 2>/dev/null | head -1)
MMPROJ=$(ls "$HUB"/snapshots/*/mmproj-BF16.gguf 2>/dev/null | head -1)
[ -n "$MODEL" ] && [ -n "$MMPROJ" ] || { echo "modèle ou mmproj introuvable dans $HUB"; exit 1; }

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
  --ro-bind "$HUB" "$HUB" \
  --bind "$WORK_DIR" "$WORK_DIR" \
  --chdir "$WORK_DIR" \
  "$LLAMA_DIR/bin/llama-server" \
    -m "$MODEL" \
    --mmproj "$MMPROJ" \
    --no-mmproj-offload \
    --alias qwen3.5-35b-a3b \
    -ngl 99 \
    --ctx-size 262144 \
    --parallel 1 \
    --slot-save-path "$SLOT_DIR" \
    -fa on \
    --cache-type-k q8_0 --cache-type-v q8_0 \
    -b 2048 -ub 512 \
    --threads 8 --threads-batch 8 \
    --host 0.0.0.0 --port 8080 \
    --jinja \
    --tools read_file,write_file,edit_file,grep_search,file_glob_search,exec_shell_command \
    --cors-origins '*' \
    --chat-template-kwargs '{"enable_thinking": false}' \
    --temp 0.7 --top-p 0.8 --top-k 20 --min-p 0 \
    --ui-mcp-proxy \
    --ui-config-file "/home/xxx/All/llm-working-dir/mcp.json"
