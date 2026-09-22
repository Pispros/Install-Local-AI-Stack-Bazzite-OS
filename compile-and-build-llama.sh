#!/bin/bash
# Build tout-en-un de la dernière version de llama.cpp (Vulkan/RADV) sur Fedora, dans distrobox.
# Cible : Radeon 780M (gfx1103). Sortie : /home/NJMER/llama.cpp/build/bin/llama-server
#
# Options (variables d'env) :
#   SKIP_DEPS=1     -> ne pas (ré)installer les paquets dnf
#   INCREMENTAL=1   -> ne pas faire de build propre (garde build/, rebuild rapide même version)
#   FORCE=1         -> autoriser le checkout master même si l'arbre git est modifié (⚠ voir plus bas)
#   JOBS=N          -> nombre de jobs de compilation (défaut : nproc ; baisse si OOM)
set -euo pipefail

LLAMA_DIR="/home/NJMER/llama.cpp"
JOBS="${JOBS:-$(nproc)}"

echo "═══ Build llama.cpp (Vulkan) — Fedora/distrobox ═══"

# --- [1/4] Dépendances -------------------------------------------------------
if [ "${SKIP_DEPS:-0}" != "1" ]; then
  echo "📦 [1/4] Installation des dépendances (dnf)..."
  sudo dnf install -y \
    git cmake ninja-build ccache \
    gcc-c++ \
    vulkan-loader-devel vulkan-headers mesa-vulkan-drivers \
    glslc glslang \
    libcurl-devel
else
  echo "📦 [1/4] Dépendances : sautées (SKIP_DEPS=1)"
fi

# --- [2/4] Source ------------------------------------------------------------
echo "🔄 [2/4] Mise à jour de la source..."
if [ ! -d "$LLAMA_DIR/.git" ]; then
  echo "    Pas de checkout — clone dans $LLAMA_DIR"
  git clone https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
fi
cd "$LLAMA_DIR"

# Garde-fou : ne pas écraser des modifs locales (ex: patchs RDNA appliqués à la main).
if [ -n "$(git status --porcelain)" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "❌ Arbre git modifié dans $LLAMA_DIR."
  echo "   Si ce sont des patchs que tu veux garder : commit/stash-les d'abord."
  echo "   Sinon relance avec  FORCE=1 ./build-llama.sh  pour passer sur master."
  exit 1
fi

OLD_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
git fetch origin
git checkout master
git pull --ff-only origin master
NEW_COMMIT="$(git rev-parse --short HEAD)"
echo "    $OLD_COMMIT -> $NEW_COMMIT"

# --- [3/4] Configuration + compilation --------------------------------------
if [ "${INCREMENTAL:-0}" != "1" ]; then
  echo "🧹 Build propre (rm -rf build) — recompile tous les shaders."
  rm -rf build
fi

echo "🛠  [3/4] Configuration CMake (Vulkan + curl + natif)..."
cmake -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_VULKAN=ON \
  -DGGML_NATIVE=ON \
  -DLLAMA_CURL=ON \
  -DGGML_CCACHE=ON

echo "⚙  Compilation (-j $JOBS)... (le 1er build est long : shaders SPIR-V)"
cmake --build build -j"$JOBS"

# --- [4/4] Vérification ------------------------------------------------------
echo "✅ [4/4] Vérification :"
BIN="$LLAMA_DIR/build/bin/llama-server"
if [ ! -x "$BIN" ]; then
  echo "❌ Binaire introuvable : $BIN"
  exit 1
fi
echo "─────────────────────────────────────────────"
"$BIN" --version 2>&1 | grep -Ei 'version|vulkan|gfx|radv' || "$BIN" --version
echo "─────────────────────────────────────────────"
echo "🎉 Terminé. Binaire : $BIN"
echo "   Note le 'version: NNNN' ci-dessus (c'est ton numéro de build)."
echo "   Relance ta stack pour l'utiliser :  ./llm-stack.sh restart"
