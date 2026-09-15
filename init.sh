#!/usr/bin/env bash
# init.sh — plug-and-play installer for the local LLM stack (Bazzite / Radeon 780M).
#
# The stack scripts already use $HOME everywhere, so they are correct on any machine.
# init.sh does the machine setup and, as a safety net, normalizes any leftover
# hard-coded /home/<user> path to THIS machine's $HOME:
#   1. install the stack scripts into $HOME (+ normalize any stray /home/<user>);
#   2. prepare the bubblewrap working dir (~/All/llm-working-dir);
#   3. write the SearXNG config (searxng/settings.yml + searxng/tavily.py);
#   4. create the 'llm' Fedora distrobox with GPU passthrough;
#   5. build llama.cpp with the Vulkan backend at ~/llama.cpp/build.
#
# Optional: export TAVILY_API_KEY=tvly-... before running to bake the key in.
# Re-runnable (idempotent). Run from the cloned repo:  ./init.sh
set -euo pipefail

# ── config ───────────────────────────────────────────────────────────────────
BOX="llm"
IMAGE="registry.fedoraproject.org/fedora-toolbox:41"   # bump if you like
WORK_DIR="$HOME/All/llm-working-dir"                    # bubblewrap sandbox (chat writes only here)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS=(llm-stack.sh start-llm.sh start-llm-fast.sh preload-models.sh warmup-llm.sh)
# ─────────────────────────────────────────────────────────────────────────────

say(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

command -v distrobox >/dev/null || { echo "distrobox missing — on Bazzite: 'ujust install-distrobox'"; exit 1; }
command -v podman    >/dev/null || { echo "podman missing"; exit 1; }

# 1) install scripts to $HOME + normalize any hard-coded /home/<user> to this $HOME
say "Installing scripts to \$HOME (paths -> $HOME)"
for f in "${SCRIPTS[@]}"; do
  [ -f "$REPO_DIR/$f" ] || { echo "missing $f in repo"; exit 1; }
  install -m 0755 "$REPO_DIR/$f" "$HOME/$f"
  # rewrite any absolute /home/<user> (xxx, NJMER, whatever) to the real $HOME
  sed -i -E "s#/home/[A-Za-z0-9._-]+#$HOME#g" "$HOME/$f"
done
echo "  ✔ llama-server binary path resolves to $HOME/llama.cpp/build in start-llm.sh + start-llm-fast.sh"

# 2) bubblewrap working dir + minimal MCP config file
say "Preparing working dir $WORK_DIR"
mkdir -p "$WORK_DIR/.slots" "$WORK_DIR/.mesa_cache"
[ -f "$WORK_DIR/mcp.json" ] || echo '{}' > "$WORK_DIR/mcp.json"

# 3) SearXNG config (consumed by SearXNG-compose.yml via ./searxng/*)
say "Writing SearXNG config to $REPO_DIR/searxng"
mkdir -p "$REPO_DIR/searxng"

# 3a) custom Tavily engine (no secret inside — safe to overwrite)
cat > "$REPO_DIR/searxng/tavily.py" <<'PY'
"""Moteur Tavily (API à clé) pour SearXNG — insensible aux blocages d'IP."""
from json import loads, dumps

about = {
    "website": "https://tavily.com",
    "official_api_documentation": "https://docs.tavily.com",
    "use_official_api": True,
    "require_api_key": True,
    "results": "JSON",
}
categories = ["general"]
paging = False

# surchargés depuis settings.yml
api_key = ""
search_depth = "basic"
max_results = 10
base_url = "https://api.tavily.com/search"

def request(query, params):
    params["method"] = "POST"
    params["url"] = base_url
    params["headers"]["Authorization"] = "Bearer " + api_key
    params["headers"]["Content-Type"] = "application/json"
    params["data"] = dumps({
        "query": query,
        "search_depth": search_depth,
        "max_results": max_results,
    })
    return params

def response(resp):
    results = []
    for r in loads(resp.text).get("results", []):
        results.append({
            "url": r.get("url", ""),
            "title": r.get("title", ""),
            "content": r.get("content", ""),
        })
    return results
PY

# 3b) settings.yml — created ONCE (won't clobber your key on re-run).
#     secret_key is generated; Tavily key comes from $TAVILY_API_KEY or a placeholder.
if [ ! -f "$REPO_DIR/searxng/settings.yml" ]; then
  SECRET=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  TAVILY_KEY="${TAVILY_API_KEY:-tvly-xxxx}"
  cat > "$REPO_DIR/searxng/settings.yml" <<EOF
use_default_settings:
  engines:
    keep_only:
      - duckduckgo
      - stackoverflow
      - arch linux wiki
      - github
      - mdn
      - pypi

server:
  secret_key: "$SECRET"
  limiter: false
  image_proxy: true

search:
  formats:
    - html
    - json
  default_lang: ""

engines:
  - name: tavily
    engine: tavily
    api_key: "$TAVILY_KEY"
    categories: [general]
    weight: 3
    timeout: 12.0
  - name: duckduckgo
    disabled: false
    categories: [general]
    timeout: 8.0
  - name: stackoverflow
    disabled: false
    categories: [it, general]
    weight: 2
    timeout: 8.0
  - name: arch linux wiki
    disabled: false
    categories: [it, general]
    weight: 2
    timeout: 8.0
EOF
  echo "  ✔ generated searxng/settings.yml (random secret_key)"
  [ "$TAVILY_KEY" = "tvly-xxxx" ] && \
    echo "  ⚠ set your Tavily key in $REPO_DIR/searxng/settings.yml (or re-run with TAVILY_API_KEY=tvly-...)"
else
  echo "  ✔ searxng/settings.yml already exists — left untouched"
fi

# 4) create the 'llm' distrobox with GPU passthrough (idempotent)
say "Creating distrobox '$BOX'"
if ! distrobox list | grep -qw "$BOX"; then
  distrobox create -Y -n "$BOX" -i "$IMAGE" \
    --additional-flags "--device /dev/dri --device /dev/kfd --group-add keep-groups"
fi
distrobox enter "$BOX" -- true   # trigger first-run init

# 5) build llama.cpp (Vulkan) INSIDE the box -> ~/llama.cpp/build
#    ($HOME is shared host<->box, so the binary lands at the path the scripts expect)
say "Building llama.cpp with Vulkan at \$HOME/llama.cpp/build"
distrobox enter "$BOX" -- bash -euc '
  SRC="$HOME/llama.cpp"; BUILD="$SRC/build"
  sudo dnf install -y -q git cmake ninja-build gcc gcc-c++ \
      vulkan-loader vulkan-loader-devel vulkan-headers mesa-vulkan-drivers \
      glslc glslang libcurl-devel
  [ -d "$SRC/.git" ] || git clone --depth=1 https://github.com/ggml-org/llama.cpp "$SRC"
  cmake -S "$SRC" -B "$BUILD" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON -DLLAMA_CURL=ON
  cmake --build "$BUILD" -j
'

# 6) done
say "Done"
cat <<EOF
Binary : $HOME/llama.cpp/build/bin/llama-server
Start  : bash ~/llm-stack.sh start   &&   bash ~/llm-stack.sh status
Search : podman compose -f "$REPO_DIR/SearXNG-compose.yml" up -d   (set your Tavily key first)
Heads-up: the first 'start' downloads the GGUF models (chat ~21 GB).
EOF
