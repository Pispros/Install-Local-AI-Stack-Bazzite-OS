#!/bin/bash
# Précharge en page cache (hôte) les .gguf RÉELLEMENT référencés par les scripts
# de lancement (lit --hf-file dedans). Aucun nom de modèle en dur : si tu changes
# de modèle dans start-llm.sh, le préchargeur suit automatiquement.
set -u

HF_HUB="$HOME/.cache/huggingface/hub"
CHAT_SCRIPT="$HOME/start-llm.sh"
FIM_SCRIPT="$HOME/start-llm-fast.sh"

# Récupère la valeur d'un flag (ex. --hf-file) dans un script de lancement.
arg_from() {
  local file=$1 flag=$2
  [ -f "$file" ] || return 1
  grep -oE -- "$flag[[:space:]]+[^[:space:]\\\\]+" "$file" | head -n1 | awk '{print $2}'
}

# Résout un .gguf (par son nom de fichier) vers son blob réel dans le cache HF.
resolve_gguf() {
  local link
  link=$(find "$HF_HUB" -iname "$1" 2>/dev/null | head -1)
  [ -z "$link" ] && return
  readlink -f "$link"
}

preload() {
  local path=$1 label=$2
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    echo "  ⚠  $label introuvable en cache"
    return
  fi
  echo "  → $label ($(du -h "$path" | cut -f1)) : $path"
  if command -v vmtouch &>/dev/null; then
    vmtouch -t "$path" >/dev/null 2>&1
  else
    cat "$path" > /dev/null
  fi
}

# Dérive les noms de fichiers depuis les scripts, puis résout les blobs.
CHAT_FILE=$(arg_from "$CHAT_SCRIPT" "--hf-file")
FIM_FILE=$(arg_from "$FIM_SCRIPT"  "--hf-file")
MAIN=$(resolve_gguf "${CHAT_FILE:-__none__}")
FIM=$(resolve_gguf "${FIM_FILE:-__none__}")

echo "🔥 Préchargement page cache..."
START=$(date +%s)
preload "$MAIN" "CHAT  (${CHAT_FILE:-?})"
preload "$FIM"  "FIM   (${FIM_FILE:-?})"
echo "✅ Terminé en $(($(date +%s)-START))s"
