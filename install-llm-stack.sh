#!/usr/bin/env bash
# =============================================================================
#  install-llm-stack.sh
#  --------------------------------------------------------------------------
#  All-in-one installer for the local LLM stack on Bazzite OS
#  Target : UM890 Pro (Ryzen 9 8945HS + Radeon 780M iGPU) — adapt if needed
#  Models / services :
#    - Chat   : Qwen3.6-35B-A3B (UD-Q4_K_XL, ~21 GiB) on port 8080
#    - FIM    : Qwen2.5-Coder-1.5B (Q8_0, ~1.7 GiB)    on port 8081
#    - Search : open-websearch MCP (podman container)  on port 3333
#
#  Idempotent : you can re-run it as many times as you want, it won't break
#  anything and picks up where it left off. Each step checks state before acting.
#
#  Usage :
#    bash install-llm-stack.sh                # do everything
#    bash install-llm-stack.sh --skip-kargs   # skip kargs config (already done)
#    bash install-llm-stack.sh --skip-build   # skip the llama.cpp build
#    bash install-llm-stack.sh --status       # just show the current state
#
#  See README.md (next to this script) for GTT and updates.
# =============================================================================

set -u  # undefined variable = error (not -e : we handle errors manually)

# ---------- Tunable variables ----------
CONTAINER_NAME="llm"
FEDORA_IMAGE="registry.fedoraproject.org/fedora-toolbox:41"
LLAMA_REPO="https://github.com/ggml-org/llama.cpp"
LLAMA_DIR="$HOME/llama.cpp"
LOG_DIR="$HOME/llm-logs"

# Target GTT : 48 GiB (leaves ~16 GiB to the system on a 64 GiB RAM machine)
GTT_PAGES_LIMIT=12582912   # 12582912 x 4 KiB = 48 GiB
GTT_POOL_SIZE=6291456      # 6291456  x 4 KiB = 24 GiB (half)
GTT_AMDGPU_SIZE=49152      # 49152 MiB = 48 GiB

# ---------- Colors ----------
R="\033[0;31m"; G="\033[0;32m"; Y="\033[0;33m"; B="\033[0;34m"; C="\033[0;36m"; N="\033[0m"
ok()    { echo -e "${G}OK${N} $*"; }
info()  { echo -e "${C}--${N} $*"; }
warn()  { echo -e "${Y}!!${N}  $*"; }
err()   { echo -e "${R}XX${N} $*" >&2; }
step()  { echo -e "\n${B}=== $* ===${N}"; }

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
    *) err "Unknown argument : $arg" ; exit 1 ;;
  esac
done

# ---------- Preflight checks ----------
preflight() {
  step "Preflight checks"

  if [ "$EUID" -eq 0 ]; then
    err "Do not run this script as root. It uses sudo where needed."
    exit 1
  fi

  if ! grep -qi 'bazzite\|fedora' /etc/os-release 2>/dev/null; then
    warn "OS not detected as Bazzite/Fedora. Continue at your own risk."
  else
    ok "Bazzite/Fedora system detected"
  fi

  if ! command -v podman >/dev/null; then
    err "podman not found — abnormal on Bazzite. Aborting."
    exit 1
  fi
  ok "podman : $(podman --version)"

  if ! command -v distrobox >/dev/null; then
    err "distrobox not found. It ships by default on Bazzite. Aborting."
    exit 1
  fi
  ok "distrobox : $(distrobox --version 2>&1 | head -1)"

  RAM_GIB=$(free -g | awk '/^Mem:/ {print $2}')
  info "Total RAM detected : ${RAM_GIB} GiB"
  if [ "$RAM_GIB" -lt 30 ]; then
    warn "Less than 32 GiB of RAM — Qwen3.6-35B won't fit. Consider downsizing."
  fi

  if [ -e /dev/dri ] && [ -e /dev/kfd ]; then
    ok "AMD GPU devices present (/dev/dri, /dev/kfd)"
  else
    warn "No /dev/kfd — the iGPU is still usable via /dev/dri/Vulkan"
  fi
}

# ---------- Status ----------
show_status() {
  step "Current stack state"

  echo -e "${C}Effective boot kargs :${N}"
  cat /proc/cmdline | tr ' ' '\n' | grep -E 'gtt|ttm|amdgpu' | sed 's/^/  /' \
    || echo "  (no GPU kargs applied)"

  echo -e "\n${C}VRAM carve-out (target of the Failed to allocate errors) :${N}"
  for f in /sys/class/drm/card*/device/mem_info_vram_total; do
    [ -f "$f" ] && awk '{printf "  VRAM total : %.0f MiB\n", $1/1048576}' < "$f"
  done

  echo -e "\n${C}GTT exposed by the driver :${N}"
  for f in /sys/class/drm/card*/device/mem_info_gtt_total; do
    [ -f "$f" ] && awk '{printf "  GTT total : %.1f GiB\n", $1/1073741824}' < "$f"
  done
  for f in /sys/class/drm/card*/device/mem_info_gtt_used; do
    [ -f "$f" ] && awk '{printf "  GTT used  : %.1f GiB\n", $1/1073741824}' < "$f"
  done

  echo -e "\n${C}distrobox container :${N}"
  if podman ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    state=$(podman inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
    echo "  $CONTAINER_NAME : $state"
  else
    echo "  $CONTAINER_NAME : absent"
  fi

  echo -e "\n${C}llama-server binary :${N}"
  if [ -x "$LLAMA_DIR/build/bin/llama-server" ]; then
    ok "$LLAMA_DIR/build/bin/llama-server"
  else
    warn "not built"
  fi

  echo -e "\n${C}Services listening :${N}"
  ss -tlnp 2>/dev/null | grep -E '8080|8081|3333' | sed 's/^/  /' \
    || echo "  (no port 8080/8081/3333 open)"

  echo -e "\n${C}llm-stack.service :${N}"
  systemctl --user is-active llm-stack.service 2>/dev/null | sed 's/^/  /' \
    || echo "  not installed"
}

if [ "$STATUS_ONLY" -eq 1 ]; then
  show_status
  exit 0
fi

# ---------- Step 1 : GTT kargs ----------
configure_kargs() {
  step "1. GTT kargs configuration (48 GiB)"

  if [ "$SKIP_KARGS" -eq 1 ]; then
    info "Skipped (--skip-kargs)"
    return
  fi

  current=$(cat /proc/cmdline)
  needs_reboot=0

  if echo "$current" | grep -q "ttm.pages_limit=$GTT_PAGES_LIMIT" \
     && echo "$current" | grep -q "amdgpu.gttsize=$GTT_AMDGPU_SIZE"; then
    ok "Kargs already applied on the current boot"
    return
  fi

  pending_kargs=$(rpm-ostree kargs 2>/dev/null || echo "")
  if echo "$pending_kargs" | grep -q "ttm.pages_limit=$GTT_PAGES_LIMIT" \
     && echo "$pending_kargs" | grep -q "amdgpu.gttsize=$GTT_AMDGPU_SIZE"; then
    warn "Kargs already staged for next boot. Reboot to activate them."
    return
  fi

  info "Applying kargs (requires sudo + a reboot afterwards)"

  # Clean up any old values before laying down the new ones
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
  ok "Kargs staged — reboot required at the end of the script."
  needs_reboot=1
  echo "NEEDS_REBOOT=1" > /tmp/.llm-stack-reboot
}

# ---------- Step 2 : distrobox container ----------
create_container() {
  step "2. Creating distrobox container '$CONTAINER_NAME'"

  if podman ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    ok "Container '$CONTAINER_NAME' already exists"
  else
    info "Creating (image $FEDORA_IMAGE)..."
    distrobox create \
      --name "$CONTAINER_NAME" \
      --image "$FEDORA_IMAGE" \
      --additional-flags "--device=/dev/dri --device=/dev/kfd" \
      --yes
    ok "Container created"
  fi

  info "Starting the container"
  podman start "$CONTAINER_NAME" >/dev/null
  ok "Container started"

  # Install dependencies via distrobox enter (idempotent)
  info "Installing dependencies inside the container (idempotent)..."
  distrobox enter "$CONTAINER_NAME" -- bash -c '
    set -e
    if ! command -v cmake >/dev/null || ! command -v vulkaninfo >/dev/null; then
      sudo dnf install -y \
        git cmake gcc gcc-c++ make pciutils curl libcurl-devel \
        vulkan-loader-devel vulkan-headers vulkan-tools \
        glslc glslang shaderc \
        jq
    fi
    echo "Dependencies OK"
  '
}

# ---------- Step 3 : build llama.cpp ----------
build_llama() {
  step "3. Building llama.cpp with Vulkan"

  if [ "$SKIP_BUILD" -eq 1 ]; then
    info "Skipped (--skip-build)"
    return
  fi

  if [ -x "$LLAMA_DIR/build/bin/llama-server" ]; then
    info "llama-server already built. To rebuild : rm -rf $LLAMA_DIR/build and re-run"
    ok "Binary present : $LLAMA_DIR/build/bin/llama-server"
    return
  fi

  if [ ! -d "$LLAMA_DIR" ]; then
    info "Cloning the llama.cpp repo..."
    git clone "$LLAMA_REPO" "$LLAMA_DIR"
  else
    info "Repo already present — pulling"
    (cd "$LLAMA_DIR" && git pull --rebase --autostash) || warn "git pull failed — continuing"
  fi

  info "Building inside the container (can take 10-20 min)..."
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
    ok "Build succeeded"
  else
    err "Build failed. See the output above."
    exit 1
  fi
}

# ---------- Step 4 : lay down the scripts ----------
install_scripts() {
  step "4. Installing the stack scripts"

  mkdir -p "$LOG_DIR"

  # --- preload-models.sh
  cat > "$HOME/preload-models.sh" << 'PRELOAD_EOF'
#!/bin/bash
# Preload the GGUFs (real blobs) into the host kernel page cache.
set -u
HF_HUB="$HOME/.cache/huggingface/hub"

resolve_gguf() {
  local link
  link=$(find "$HF_HUB" -iname "$1" 2>/dev/null | head -1)
  [ -z "$link" ] && return
  readlink -f "$link"
}

MAIN=$(resolve_gguf "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf")
FIM=$(resolve_gguf "Qwen2.5-Coder-1.5B-Q8_0.gguf")

preload() {
  if [ -z "$1" ] || [ ! -f "$1" ]; then
    echo "  !! $2 not found"
    return
  fi
  echo "  -> $2 ($(du -h "$1" | cut -f1)) : $1"
  if command -v vmtouch &>/dev/null; then
    vmtouch -t "$1" >/dev/null 2>&1
  else
    cat "$1" > /dev/null
  fi
}

echo "Preloading page cache..."
START=$(date +%s)
preload "$MAIN" "Qwen3.6-35B-A3B"
preload "$FIM"  "Qwen2.5-Coder-1.5B (FIM)"
echo "Done in $(($(date +%s)-START))s"
PRELOAD_EOF
  chmod +x "$HOME/preload-models.sh"
  ok "$HOME/preload-models.sh"

  # --- start-llm.sh (chat, inside the distrobox)
  cat > "$HOME/start-llm.sh" << 'CHAT_EOF'
#!/bin/bash
# Main chat server : Qwen3.6-35B-A3B on the 780M (port 8080)

export AMD_VULKAN_ICD=RADV
export RADV_PERFTEST=gpl
export RADV_DEBUG=zerovram                 # ignore the 1 GiB VRAM carve-out, route everything via GTT
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
  --ctx-size 138240 \
  --parallel 1 \
  -fa on \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  -b 2048 -ub 1024 \
  --threads 8 --threads-batch 8 \
  --no-warmup \
  --host 0.0.0.0 --port 8080 \
  --jinja --reasoning-format deepseek \
  --temp 0.7 --top-p 0.8 --top-k 20 --min-p 0.0 \
  --presence-penalty 1.5 \
  --chat-template-kwargs '{"enable_thinking":false}' \
  --ui-mcp-proxy
CHAT_EOF
  chmod +x "$HOME/start-llm.sh"
  ok "$HOME/start-llm.sh"

  # --- start-llm-fast.sh (FIM, inside the distrobox)
  cat > "$HOME/start-llm-fast.sh" << 'FIM_EOF'
#!/bin/bash
# FIM server (editor autocomplete) : Qwen2.5-Coder-1.5B on the 780M (port 8081)

export AMD_VULKAN_ICD=RADV
export RADV_PERFTEST=gpl
export RADV_DEBUG=zerovram                 # ignore the 1 GiB VRAM carve-out, route everything via GTT
export GGML_VK_ALLOW_SYSMEM_FALLBACK=1
export MESA_SHADER_CACHE_DIR="$HOME/.cache/mesa_shader_cache"
export MESA_SHADER_CACHE_MAX_SIZE="4G"
export OMP_NUM_THREADS=4
export GOMP_CPU_AFFINITY="8-11"
mkdir -p "$MESA_SHADER_CACHE_DIR"

exec "$HOME/llama.cpp/build/bin/llama-server" \
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
FIM_EOF
  chmod +x "$HOME/start-llm-fast.sh"
  ok "$HOME/start-llm-fast.sh"

  # --- open-websearch : web search MCP (podman container, no API key)
  mkdir -p "$HOME/open-websearch"
  cat > "$HOME/open-websearch/docker-compose.yaml" << 'SEARCH_EOF'
# open-webSearch MCP server — NO API KEY REQUIRED
# Multi-engine web search (DuckDuckGo, Bing, Brave, ...) for the llama.cpp WebUI.
#
# Started/stopped automatically by ~/llm-stack.sh (podman compose).
# MCP endpoint : http://127.0.0.1:3333/mcp   (streamable HTTP)
# SSE fallback : http://127.0.0.1:3333/sse
#
# WARNING: llama-server's cors-proxy is an open proxy (SSRF risk):
#    keep the stack on a trusted network, do not expose it to the internet.
services:
  open-websearch:
    image: ghcr.io/aas-ee/open-web-search:latest
    container_name: open-websearch
    restart: unless-stopped
    init: true
    environment:
      - ENABLE_CORS=true
      - CORS_ORIGIN=*
      - DEFAULT_SEARCH_ENGINE=duckduckgo
      - ALLOWED_SEARCH_ENGINES=duckduckgo,bing,brave
      - PORT=3000
      # Outbound proxy if your network needs one to reach the engines:
      # - USE_PROXY=true
      # - PROXY_URL=http://your-proxy-host:port
    ports:
      - "3333:3000"   # host:container
    deploy:
      restart_policy:
        condition: any
        delay: 5s
SEARCH_EOF
  ok "$HOME/open-websearch/docker-compose.yaml"

  # --- llm-stack.sh (host orchestrator)
  cat > "$HOME/llm-stack.sh" << 'STACK_EOF'
#!/bin/bash
# Orchestrator : preload on the host, then launch the 2 servers in distrobox
# plus the web-search MCP container.
set -u
LOGDIR="$HOME/llm-logs"
mkdir -p "$LOGDIR"

CONTAINER="llm"
MAIN_SCRIPT="$HOME/start-llm.sh"
FIM_SCRIPT="$HOME/start-llm-fast.sh"
SEARCH_COMPOSE="$HOME/open-websearch/docker-compose.yaml"

cmd="${1:-start}"

stop_all() {
  echo "Stopping servers..."
  distrobox enter "$CONTAINER" -- pkill -f "llama-server" 2>/dev/null || true
  sleep 2
  distrobox enter "$CONTAINER" -- pkill -9 -f "llama-server" 2>/dev/null || true
  rm -f "$LOGDIR"/*.pid
  echo "Stopping the web-search MCP..."
  podman compose -f "$SEARCH_COMPOSE" down 2>/dev/null || true
  echo "Stopped"
}

wait_ready() {
  local port=$1 timeout=$2 label=$3
  echo -n "    Waiting for $label (port $port)"
  for i in $(seq 1 "$timeout"); do
    if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      echo " — ready in ${i}s"
      return 0
    fi
    echo -n "."
    sleep 1
  done
  echo " timeout"
  return 1
}

warmup_background() {
  (
    sleep 3
    curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"qwen3.6-a3b","messages":[{"role":"user","content":"Hello"}],"max_tokens":20,"cache_prompt":true}' \
      > "$LOGDIR/warmup.log" 2>&1
  ) &
}

start_all() {
  echo "=== LLM stack — Qwen3.6-35B + Coder-1.5B FIM + WebSearch MCP ==="

  echo "[1/5] podman start $CONTAINER"
  podman start "$CONTAINER" >/dev/null

  echo "[2/5] Preloading page cache (host)..."
  "$HOME/preload-models.sh"

  echo "[3/5] Qwen3.6-35B on :8080..."
  nohup distrobox enter "$CONTAINER" -- "$MAIN_SCRIPT" \
    > "$LOGDIR/main.log" 2>&1 &
  echo $! > "$LOGDIR/main.pid"
  wait_ready 8080 180 "chat"

  echo "[4/5] Coder-1.5B FIM on :8081..."
  nohup distrobox enter "$CONTAINER" -- "$FIM_SCRIPT" \
    > "$LOGDIR/fim.log" 2>&1 &
  echo $! > "$LOGDIR/fim.pid"
  wait_ready 8081 60 "FIM"

  echo "[5/5] open-websearch MCP on :3333..."
  if podman compose -f "$SEARCH_COMPOSE" up -d >/dev/null 2>&1; then
    sleep 2
    if podman ps --format '{{.Names}}' | grep -qx "open-websearch"; then
      echo "    open-websearch — up  (MCP: http://127.0.0.1:3333/mcp)"
    else
      echo "    open-websearch — started but container not visible (see: podman logs open-websearch)"
    fi
  else
    echo "    open-websearch — failed to start (podman compose missing? see README)"
  fi

  echo "Warmup launched in the background (see $LOGDIR/warmup.log)"
  warmup_background

  echo "=== Stack ready ==="
}

status() {
  echo "-- Stack status --"
  for port_label in "8080:chat" "8081:fim"; do
    port="${port_label%%:*}"; label="${port_label##*:}"
    if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      echo "  up   $label (port $port)"
    else
      echo "  down $label (port $port)"
    fi
  done
  if podman ps --format '{{.Names}}' | grep -qx "open-websearch"; then
    echo "  up   search (port 3333, MCP /mcp)"
  else
    echo "  down search (port 3333)"
  fi
}

logs() {
  echo "-- main.log (last 20 lines) --"
  tail -n 20 "$LOGDIR/main.log" 2>/dev/null
  echo
  echo "-- fim.log (last 20 lines) --"
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

# ---------- Step 5 : systemd --user service ----------
install_service() {
  step "5. Installing the systemd --user service"

  # Clean up old services if present
  systemctl --user stop llama-server.service llama-server-fast.service 2>/dev/null
  systemctl --user disable llama-server.service llama-server-fast.service 2>/dev/null
  rm -f "$HOME/.config/systemd/user/llama-server.service" \
        "$HOME/.config/systemd/user/llama-server-fast.service"

  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/llm-stack.service" << EOF
[Unit]
Description=LLM stack (Qwen3.6-35B + Coder-1.5B FIM + WebSearch MCP in distrobox/podman)
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
  ok "llm-stack.service enabled (auto start at login)"
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

step "Installation complete"

if [ -f /tmp/.llm-stack-reboot ]; then
  rm -f /tmp/.llm-stack-reboot
  warn "Reboot required to activate the 48 GiB GTT kargs."
  warn "After reboot, run :   ~/llm-stack.sh start"
  echo
  read -rp "Reboot now ? [y/N] " ans
  case "$ans" in
    [yY]) sudo systemctl reboot ;;
    *)    info "Reboot when ready with : sudo systemctl reboot" ;;
  esac
else
  info "You can now launch the stack :"
  echo "  ~/llm-stack.sh start"
  echo
  info "Check the state :"
  echo "  ~/llm-stack.sh status"
  echo "  bash $0 --status"
fi
