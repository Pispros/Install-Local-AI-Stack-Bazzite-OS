#!/bin/bash
# Précharge en page cache (hôte) les .gguf RÉELLEMENT référencés par les scripts
# de lancement. Lit --hf-file ; à défaut, lit -hf repo[:file] et résout le gguf
# du repo dans le cache HF. Aucun nom de modèle en dur.
set -u

HF_HUB="$HOME/.cache/huggingface/hub"
CHAT_SCRIPT="$HOME/start-llm.sh"
FIM_SCRIPT="$HOME/start-llm-fast.sh"

# Récupère la valeur d'un flag (ex. --hf-file, -hf) dans un script.
arg_from() {
  local file=$1 flag=$2
  [ -f "$file" ] || return 1
  grep -oE -- "$flag[[:space:]]+[^[:space:]\\\\]+" "$file" | head -n1 | awk '{print $2}'
}

# Résout un .gguf (par son nom de fichier) vers son blob réel.
resolve_gguf() {
  local link
  link=$(find "$HF_HUB" -iname "$1" 2>/dev/null | head -1)
  [ -z "$link" ] && return
  readlink -f "$link"
}

# "org/name[:quant]" -> .../hub/models--org--name
repo_to_cachedir() {
  echo "$HF_HUB/models--$(echo "$1" | sed 's#:.*##; s#/#--#g')"
}

# Trouve un .gguf dans le cache d'un repo (utile quand seul -hf repo est donné).
resolve_repo_gguf() {
  local d
  d=$(repo_to_cachedir "$1")
  [ -d "$d" ] || return
  find "$d" -iname '*.gguf' 2>/dev/null | head -1 | xargs -r readlink -f
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

# CHAT : via --hf-file
CHAT_FILE=$(arg_from "$CHAT_SCRIPT" "--hf-file")
MAIN=$(resolve_gguf "${CHAT_FILE:-__none__}")

# FIM : --hf-file si présent, sinon -hf repo[:file]
FIM_FILE=$(arg_from "$FIM_SCRIPT" "--hf-file")
FIM_REPO=$(arg_from "$FIM_SCRIPT" "-hf")
if [ -n "${FIM_FILE:-}" ]; then
  FIM=$(resolve_gguf "$FIM_FILE")
  FIM_LABEL="$FIM_FILE"
else
  FIM=$(resolve_repo_gguf "${FIM_REPO:-__none__}")
  FIM_LABEL="${FIM_REPO:-?}"
fi

echo "🔥 Préchargement page cache..."
START=$(date +%s)
preload "$MAIN" "CHAT  (${CHAT_FILE:-?})"
preload "$FIM"  "FIM   (${FIM_LABEL})"
echo "✅ Terminé en $(($(date +%s)-START))s"
