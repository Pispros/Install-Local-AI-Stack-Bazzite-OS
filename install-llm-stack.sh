#!/usr/bin/env bash
# =============================================================================
#  install-llm-stack.sh
#  --------------------------------------------------------------------------
#  Installation tout-en-un de la stack LLM locale sur Bazzite OS
#  Cible : UM890 Pro (Ryzen 9 8945HS + Radeon 780M iGPU) — adapte si besoin
#  Modèles :
#    - Chat   : Qwen3.6-35B-A3B (UD-Q4_K_XL, ~21 GiB) sur port 8080
#    - FIM    : Qwen2.5-Coder-3B (Q8_0, ~3 GiB)        sur port 8081
#
#  Idempotent : tu peux le relancer autant de fois que tu veux, il ne casse
#  rien et reprend là où il en est. Chaque étape vérifie l'état avant d'agir.
#
#  Usage :
#    bash install-llm-stack.sh                # tout faire
#    bash install-llm-stack.sh --skip-kargs   # sauter la conf kargs (déjà faite)
#    bash install-llm-stack.sh --skip-build   # sauter la compile llama.cpp
#    bash install-llm-stack.sh --status       # juste afficher l'état
#
#  Voir README.md (à côté de ce script) pour la GTT et les mises à jour.
# =============================================================================

set -u  # variable non définie = erreur (pas -e : on gère les erreurs à la main)

# ---------- Variables ajustables ----------
CONTAINER_NAME="llm"
FEDORA_IMAGE="registry.fedoraproject.org/fedora-toolbox:41"
LLAMA_REPO="https://github.com/ggml-org/llama.cpp"
LLAMA_DIR="$HOME/llama.cpp"
LOG_DIR="$HOME/llm-logs"

# GTT cible : 48 GiB (laisse ~16 GiB au système sur une machine 64 GiB RAM)
GTT_PAGES_LIMIT=12582912   # 12582912 × 4 KiB = 48 GiB
GTT_POOL_SIZE=6291456      # 6291456  × 4 KiB = 24 GiB (moitié)
GTT_AMDGPU_SIZE=49152      # 49152 MiB = 48 GiB

# ---------- Couleurs ----------
R="\033[0;31m"; G="\033[0;32m"; Y="\033[0;33m"; B="\033[0;34m"; C="\033[0;36m"; N="\033[0m"
ok()    { echo -e "${G}✅${N} $*"; }
info()  { echo -e "${C}ℹ️${N}  $*"; }
warn()  { echo -e "${Y}⚠️${N}  $*"; }
err()   { echo -e "${R}❌${N} $*" >&2; }
step()  { echo -e "\n${B}═══ $* ═══${N}"; }

# ---------- Flags ----------
SKIP_KARGS=0; SKIP_BUILD=0; STATUS_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --skip-kargs) SKIP_KARGS=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --status)     STATUS_ONLY=1 ;;
    -h|--help)
      sed -n '2,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) err "Argument inconnu : $arg" ; exit 1 ;;
  esac
done

# ---------- Vérifs préalables ----------
preflight() {
  step "Vérifications préalables"

  if [ "$EUID" -eq 0 ]; then
    err "Ne lance pas ce script en root. Il utilise sudo où c'est nécessaire."
    exit 1
  fi

  if ! grep -qi 'bazzite\|fedora' /etc/os-release 2>/dev/null; then
    warn "OS non détecté comme Bazzite/Fedora. Continue à tes risques."
  else
    ok "Système Bazzite/Fedora détecté"
  fi

  if ! command -v podman >/dev/null; then
    err "podman introuvable — anormal sur Bazzite. Abandon."
    exit 1
  fi
  ok "podman : $(podman --version)"

  if ! command -v distrobox >/dev/null; then
    err "distrobox introuvable. Sur Bazzite il est livré d'office. Abandon."
    exit 1
  fi
  ok "distrobox : $(distrobox --version 2>&1 | head -1)"

  RAM_GIB=$(free -g | awk '/^Mem:/ {print $2}')
  info "RAM totale détectée : ${RAM_GIB} GiB"
  if [ "$RAM_GIB" -lt 30 ]; then
    warn "Moins de 32 GiB de RAM — Qwen3.6-35B ne tiendra pas. Pense à réduire."
  fi

  if [ -e /dev/dri ] && [ -e /dev/kfd ]; then
    ok "Périphériques GPU AMD présents (/dev/dri, /dev/kfd)"
  else
    warn "Pas de /dev/kfd — le iGPU sera quand même utilisable via /dev/dri/Vulkan"
  fi
}

# ---------- Statut ----------
show_status() {
  step "État actuel de la stack"

  echo -e "${C}Kargs effectifs au boot :${N}"
  cat /proc/cmdline | tr ' ' '\n' | grep -E 'gtt|ttm|amdgpu' | sed 's/^/  /' \
    || echo "  (aucun karg GPU appliqué)"

  echo -e "\n${C}GTT exposée par le driver :${N}"
  for f in /sys/class/drm/card*/device/mem_info_gtt_total; do
    [ -f "$f" ] && awk '{printf "  GTT total : %.1f GiB\n", $1/1073741824}' < "$f"
  done
  for f in /sys/class/drm/card*/device/mem_info_gtt_used; do
    [ -f "$f" ] && awk '{printf "  GTT used  : %.1f GiB\n", $1/1073741824}' < "$f"
  done

  echo -e "\n${C}Container distrobox :${N}"
  if podman ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    state=$(podman inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
    echo "  $CONTAINER_NAME : $state"
  else
    echo "  $CONTAINER_NAME : absent"
  fi

  echo -e "\n${C}Binaire llama-server :${N}"
  if [ -x "$LLAMA_DIR/build/bin/llama-server" ]; then
    ok "$LLAMA_DIR/build/bin/llama-server"
  else
    warn "non compilé"
  fi

  echo -e "\n${C}Services en écoute :${N}"
  ss -tlnp 2>/dev/null | grep -E '8080|8081' | sed 's/^/  /' \
    || echo "  (aucun port 8080/8081 ouvert)"

  echo -e "\n${C}llm-stack.service :${N}"
  systemctl --user is-active llm-stack.service 2>/dev/null | sed 's/^/  /' \
    || echo "  non installé"
}

if [ "$STATUS_ONLY" -eq 1 ]; then
  show_status
  exit 0
fi

# ---------- Étape 1 : kargs GTT ----------
configure_kargs() {
  step "1. Configuration des kargs GTT (48 GiB)"

  if [ "$SKIP_KARGS" -eq 1 ]; then
    info "Sauté (--skip-kargs)"
    return
  fi

  current=$(cat /proc/cmdline)
  needs_reboot=0

  if echo "$current" | grep -q "ttm.pages_limit=$GTT_PAGES_LIMIT" \
     && echo "$current" | grep -q "amdgpu.gttsize=$GTT_AMDGPU_SIZE"; then
    ok "Kargs déjà appliqués au boot courant"
    return
  fi

  pending_kargs=$(rpm-ostree kargs 2>/dev/null || echo "")
  if echo "$pending_kargs" | grep -q "ttm.pages_limit=$GTT_PAGES_LIMIT" \
     && echo "$pending_kargs" | grep -q "amdgpu.gttsize=$GTT_AMDGPU_SIZE"; then
    warn "Kargs déjà stagés pour le prochain boot. Reboote pour les activer."
    return
  fi

  info "Application des kargs (nécessite sudo + reboot ensuite)"

  # On nettoie d'éventuelles anciennes valeurs avant de poser les nouvelles
  cur_pages=$(echo "$current" | grep -oP 'ttm\.pages_limit=\K\d+' || true)
  cur_pool=$(echo "$current" | grep -oP 'ttm\.page_pool_size=\K\d+' || true)
  cur_gtt=$(echo "$current" | grep -oP 'amdgpu\.gttsize=\K\d+' || true)

  args=()
  if [ -n "$cur_pages" ]; then
    args+=( "--replace=ttm.pages_limit=${cur_pages}=${GTT_PAGES_LIMIT}" )
  else
    args+=( "--append-if-missing=ttm.pages_limit=${GTT_PAGES_LIMIT}" )
  fi
  if [ -n "$cur_pool" ]; then
    args+=( "--replace=ttm.page_pool_size=${cur_pool}=${GTT_POOL_SIZE}" )
  else
    args+=( "--append-if-missing=ttm.page_pool_size=${GTT_POOL_SIZE}" )
  fi
  if [ -n "$cur_gtt" ] && [ "$cur_gtt" != "$GTT_AMDGPU_SIZE" ]; then
    args+=( "--replace=amdgpu.gttsize=${cur_gtt}=${GTT_AMDGPU_SIZE}" )
  else
    args+=( "--append-if-missing=amdgpu.gttsize=${GTT_AMDGPU_SIZE}" )
  fi

  sudo rpm-ostree kargs "${args[@]}"
  ok "Kargs stagés — reboot requis à la fin du script."
  needs_reboot=1
  echo "NEEDS_REBOOT=1" > /tmp/.llm-stack-reboot
}

# ---------- Étape 2 : container distrobox ----------
create_container() {
  step "2. Création du container distrobox '$CONTAINER_NAME'"

  if podman ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    ok "Container '$CONTAINER_NAME' existe déjà"
  else
    info "Création (image $FEDORA_IMAGE)…"
    distrobox create \
      --name "$CONTAINER_NAME" \
      --image "$FEDORA_IMAGE" \
      --additional-flags "--device=/dev/dri --device=/dev/kfd" \
      --yes
    ok "Container créé"
  fi

  info "Démarrage du container"
  podman start "$CONTAINER_NAME" >/dev/null
  ok "Container démarré"

  # Installe les dépendances via distrobox enter (idempotent)
  info "Installation des dépendances dans le container (idempotent)…"
  distrobox enter "$CONTAINER_NAME" -- bash -c '
    set -e
    if ! command -v cmake >/dev/null || ! command -v vulkaninfo >/dev/null; then
      sudo dnf install -y \
        git cmake gcc gcc-c++ make pciutils curl libcurl-devel \
        vulkan-loader-devel vulkan-headers vulkan-tools \
        glslc glslang shaderc \
        jq
    fi
    echo "✅ Dépendances OK"
  '
}

# ---------- Étape 3 : compile llama.cpp ----------
build_llama() {
  step "3. Compilation de llama.cpp avec Vulkan"

  if [ "$SKIP_BUILD" -eq 1 ]; then
    info "Sauté (--skip-build)"
    return
  fi

  if [ -x "$LLAMA_DIR/build/bin/llama-server" ]; then
    info "llama-server déjà compilé. Pour rebuilder : --skip-build=no + rm -rf $LLAMA_DIR/build"
    ok "Binaire présent : $LLAMA_DIR/build/bin/llama-server"
    return
  fi

  if [ ! -d "$LLAMA_DIR" ]; then
    info "Clone du repo llama.cpp…"
    git clone "$LLAMA_REPO" "$LLAMA_DIR"
  else
    info "Repo déjà présent — pull"
    (cd "$LLAMA_DIR" && git pull --rebase --autostash) || warn "git pull a échoué — on continue"
  fi

  info "Compilation dans le container (peut prendre 10-20 min)…"
  distrobox enter "$CONTAINER_NAME" -- bash -c "
    set -e
    cd $LLAMA_DIR
    cmake -B build \
      -DBUILD_SHARED_LIBS=OFF \
      -DGGML_VULKAN=ON \
      -DCMAKE_BUILD_TYPE=Release
    cmake --build build --config Release -j\$(nproc) \
      --target llama-cli llama-server llama-gguf-split
  "

  if [ -x "$LLAMA_DIR/build/bin/llama-server" ]; then
    ok "Compilation réussie"
  else
    err "Compilation échouée. Voir la sortie ci-dessus."
    exit 1
  fi
}

# ---------- Étape 4 : pose des scripts ----------
install_scripts() {
  step "4. Installation des scripts de la stack"

  mkdir -p "$LOG_DIR"

  # --- preload-models.sh
  cat > "$HOME/preload-models.sh" << 'PRELOAD_EOF'
#!/bin/bash
# Précharge les GGUF (vrais blobs) dans le page cache du kernel hôte.
set -u
HF_HUB="$HOME/.cache/huggingface/hub"

resolve_gguf() {
  local link
  link=$(find "$HF_HUB" -iname "$1" 2>/dev/null | head -1)
  [ -z "$link" ] && return
  readlink -f "$link"
}

MAIN=$(resolve_gguf "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf")
FIM=$(resolve_gguf "Qwen2.5-Coder-3B-Q8_0.gguf")

preload() {
  if [ -z "$1" ] || [ ! -f "$1" ]; then
    echo "  ⚠  $2 introuvable"
    return
  fi
  echo "  → $2 ($(du -h "$1" | cut -f1)) : $1"
  if command -v vmtouch &>/dev/null; then
    vmtouch -t "$1" >/dev/null 2>&1
  else
    cat "$1" > /dev/null
  fi
}

echo "🔥 Préchargement page cache..."
START=$(date +%s)
preload "$MAIN" "Qwen3.6-35B-A3B"
preload "$FIM"  "Qwen2.5-Coder-3B (FIM)"
echo "✅ Terminé en $(($(date +%s)-START))s"
PRELOAD_EOF
  chmod +x "$HOME/preload-models.sh"
  ok "$HOME/preload-models.sh"

  # --- start-llm.sh (chat, dans la distrobox)
  cat > "$HOME/start-llm.sh" << 'CHAT_EOF'
#!/bin/bash
# Serveur chat principal : Qwen3.6-35B-A3B sur 780M (port 8080)

export AMD_VULKAN_ICD=RADV
export RADV_PERFTEST=gpl
export GGML_VK_ALLOW_SYSMEM_FALLBACK=1
export MESA_SHADER_CACHE_DIR="$HOME/.cache/mesa_shader_cache"
export MESA_SHADER_CACHE_MAX_SIZE="4G"
export OMP_NUM_THREADS=8
export GOMP_CPU_AFFINITY="0-7"
mkdir -p "$MESA_SHADER_CACHE_DIR"

exec "$HOME/llama.cpp/build/bin/llama-server" \
  --hf-repo unsloth/Qwen3.6-35B-A3B-GGUF \
  --hf-file Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf \
  --no-mmproj \
  --alias qwen3.6-a3b \
  -ngl 99 \
  --ctx-size 65536 \
  --parallel 1 \
  -fa on \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  -b 2048 -ub 1024 \
  --threads 8 --threads-batch 8 \
  --no-mmap --mlock --no-warmup \
  --host 0.0.0.0 --port 8080 \
  --jinja --reasoning-format deepseek \
  --temp 0.7 --top-p 0.8 --top-k 20 --min-p 0.0 \
  --presence-penalty 1.5 \
  --chat-template-kwargs '{"enable_thinking":false}' \
  --webui-mcp-proxy
CHAT_EOF
  chmod +x "$HOME/start-llm.sh"
  ok "$HOME/start-llm.sh"

  # --- start-llm-fast.sh (FIM, dans la distrobox)
  cat > "$HOME/start-llm-fast.sh" << 'FIM_EOF'
#!/bin/bash
# Serveur FIM (autocomplétion éditeur) : Qwen2.5-Coder-3B sur 780M (port 8081)

export AMD_VULKAN_ICD=RADV
export RADV_PERFTEST=gpl
export GGML_VK_ALLOW_SYSMEM_FALLBACK=1
export MESA_SHADER_CACHE_DIR="$HOME/.cache/mesa_shader_cache"
export MESA_SHADER_CACHE_MAX_SIZE="4G"
export OMP_NUM_THREADS=4
export GOMP_CPU_AFFINITY="8-11"
mkdir -p "$MESA_SHADER_CACHE_DIR"

exec "$HOME/llama.cpp/build/bin/llama-server" \
  -hf ggml-org/Qwen2.5-Coder-3B-Q8_0-GGUF \
  --alias qwen-coder-fim \
  -ngl 99 \
  --ctx-size 8192 \
  --parallel 1 \
  -fa on \
  --cache-reuse 256 \
  -b 1024 -ub 1024 \
  --threads 4 --threads-batch 4 \
  --no-mmap --mlock --no-warmup \
  --host 0.0.0.0 --port 8081 \
  --temp 0.1 --top-p 0.9
FIM_EOF
  chmod +x "$HOME/start-llm-fast.sh"
  ok "$HOME/start-llm-fast.sh"

  # --- llm-stack.sh (orchestrateur hôte)
  cat > "$HOME/llm-stack.sh" << 'STACK_EOF'
#!/bin/bash
# Orchestrateur : précharge sur l'hôte puis lance les 2 serveurs dans distrobox.
set -u
LOGDIR="$HOME/llm-logs"
mkdir -p "$LOGDIR"

CONTAINER="llm"
MAIN_SCRIPT="$HOME/start-llm.sh"
FIM_SCRIPT="$HOME/start-llm-fast.sh"

cmd="${1:-start}"

stop_all() {
  echo "⏹  Arrêt des serveurs..."
  distrobox enter "$CONTAINER" -- pkill -f "llama-server" 2>/dev/null || true
  sleep 2
  distrobox enter "$CONTAINER" -- pkill -9 -f "llama-server" 2>/dev/null || true
  rm -f "$LOGDIR"/*.pid
  echo "✅ Arrêté"
}

wait_ready() {
  local port=$1 timeout=$2 label=$3
  echo -n "    Attente $label (port $port)"
  for i in $(seq 1 "$timeout"); do
    if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      echo " — prêt en ${i}s ✅"
      return 0
    fi
    echo -n "."
    sleep 1
  done
  echo " ❌ timeout"
  return 1
}

warmup_background() {
  (
    sleep 3
    curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"qwen3.6-a3b","messages":[{"role":"user","content":"Bonjour"}],"max_tokens":20,"cache_prompt":true}' \
      > "$LOGDIR/warmup.log" 2>&1
  ) &
}

start_all() {
  echo "═══ Stack LLM — Qwen3.6-35B + Coder-3B FIM ═══"

  echo "📦 [1/4] podman start $CONTAINER"
  podman start "$CONTAINER" >/dev/null

  echo "🔥 [2/4] Préchargement page cache (hôte)..."
  "$HOME/preload-models.sh"

  echo "🧠 [3/4] Qwen3.6-35B sur :8080..."
  nohup distrobox enter "$CONTAINER" -- "$MAIN_SCRIPT" \
    > "$LOGDIR/main.log" 2>&1 &
  echo $! > "$LOGDIR/main.pid"
  wait_ready 8080 180 "chat"

  echo "⚡ [4/4] Coder-3B FIM sur :8081..."
  nohup distrobox enter "$CONTAINER" -- "$FIM_SCRIPT" \
    > "$LOGDIR/fim.log" 2>&1 &
  echo $! > "$LOGDIR/fim.pid"
  wait_ready 8081 60 "FIM"

  echo "🌡  Warmup lancé en arrière-plan (voir $LOGDIR/warmup.log)"
  warmup_background

  echo "═══ Stack prête ═══"
}

status() {
  echo "── Stack status ──"
  for port_label in "8080:chat" "8081:fim"; do
    port="${port_label%%:*}"; label="${port_label##*:}"
    if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      echo "  ✅ $label : up (port $port)"
    else
      echo "  ❌ $label : down (port $port)"
    fi
  done
}

logs() {
  echo "── main.log (20 dernières lignes) ──"
  tail -n 20 "$LOGDIR/main.log" 2>/dev/null
  echo
  echo "── fim.log (20 dernières lignes) ──"
  tail -n 20 "$LOGDIR/fim.log" 2>/dev/null
}

case "$cmd" in
  start)   start_all ;;
  stop)    stop_all ;;
  restart) stop_all; sleep 1; start_all ;;
  status)  status ;;
  logs)    logs ;;
  *)       echo "Usage: $0 {start|stop|restart|status|logs}" ; exit 1 ;;
esac
STACK_EOF
  chmod +x "$HOME/llm-stack.sh"
  ok "$HOME/llm-stack.sh"
}

# ---------- Étape 5 : service systemd --user ----------
install_service() {
  step "5. Installation du service systemd --user"

  # Nettoyage d'anciens services s'ils existent
  systemctl --user stop llama-server.service llama-server-fast.service 2>/dev/null
  systemctl --user disable llama-server.service llama-server-fast.service 2>/dev/null
  rm -f "$HOME/.config/systemd/user/llama-server.service" \
        "$HOME/.config/systemd/user/llama-server-fast.service"

  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/llm-stack.service" << EOF
[Unit]
Description=Stack LLM (Qwen3.6-35B + Coder-3B FIM dans distrobox)
After=default.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=%h/llm-stack.sh start
ExecStop=%h/llm-stack.sh stop
TimeoutStartSec=300
TimeoutStopSec=60

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable llm-stack.service
  sudo loginctl enable-linger "$USER" >/dev/null 2>&1 || true
  ok "Service llm-stack.service activé (lancement auto au login)"
}

# =============================================================================
# MAIN
# =============================================================================

preflight
configure_kargs
create_container
build_llama
install_scripts
install_service

step "Installation terminée"

if [ -f /tmp/.llm-stack-reboot ]; then
  rm -f /tmp/.llm-stack-reboot
  warn "Reboot requis pour activer les kargs GTT 48 GiB."
  warn "Après reboot, lance :   ~/llm-stack.sh start"
  echo
  read -rp "Reboote maintenant ? [y/N] " ans
  case "$ans" in
    [yY]) sudo systemctl reboot ;;
    *)    info "Reboote quand tu seras prêt avec : sudo systemctl reboot" ;;
  esac
else
  info "Tu peux maintenant lancer la stack :"
  echo "  ~/llm-stack.sh start"
  echo
  info "Vérifier l'état :"
  echo "  ~/llm-stack.sh status"
  echo "  bash $0 --status"
fi
