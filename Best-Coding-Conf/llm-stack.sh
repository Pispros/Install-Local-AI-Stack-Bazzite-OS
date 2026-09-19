#!/bin/bash
# Orchestrateur : (re)lance les 2 serveurs dans le distrobox et vérifie leur santé.
# Le TÉLÉCHARGEMENT des modèles est géré par les scripts start-* eux-mêmes (download-if-missing) ;
# le stack ne fait plus de préchargement page-cache — il lance et vérifie, c'est tout.
# Chat = Qwen3-Coder-Next (MoE qwen3_next / Gated DeltaNet).
#   ⚠ GDN : reprocessing complet du prompt à chaque tour (pas de KV cache reuse propre
#           comme le 30B-2507) -> follow-ups plus lents.
# FIM  = Qwen2.5-Coder-3B (Q5_K_M) pour l'autocomplétion de code.
set -u

LOGDIR="$HOME/llm-logs"
mkdir -p "$LOGDIR"

CONTAINER="llm"
MAIN_SCRIPT="/home/NJMER/start-llm.sh"
FIM_SCRIPT="/home/NJMER/start-llm-fast.sh"

# --- Alias : DOIVENT correspondre à --alias dans les scripts start-* -----------
CHAT_ALIAS="qwen3-coder-next"
CHAT_PORT=8080
FIM_ALIAS="qwen2.5-coder-3b"
FIM_PORT=8081
# ------------------------------------------------------------------------------

cmd="${1:-start}"

stop_all() {
  echo "⏹  Arrêt des serveurs..."
  distrobox enter "$CONTAINER" -- pkill -f "llama-server" </dev/null 2>/dev/null || true
  sleep 2
  distrobox enter "$CONTAINER" -- pkill -9 -f "llama-server" </dev/null 2>/dev/null || true
  rm -f "$LOGDIR"/*.pid
  echo "✅ Arrêté"
}

wait_ready() {
  local port=$1 timeout=$2 label=$3 pidfile=${4:-}
  echo -n "    Attente $label (port $port)"
  local i=0
  while true; do
    if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      echo " — prêt en ${i}s ✅"
      return 0
    fi
    # si le process détaché est mort -> vrai échec, on n'attend pas pour rien
    if [ -n "$pidfile" ] && [ -f "$pidfile" ] && ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      echo " ❌ process terminé (voir log)"
      return 1
    fi
    i=$((i+1))
    if [ "$i" -ge "$timeout" ]; then
      echo " ❌ timeout"
      return 1
    fi
    echo -n "."
    sleep 1
  done
}

# Lance un script dans le distrobox, totalement détaché du terminal.
launch_detached() {
  local script=$1 logfile=$2 pidfile=$3
  setsid nohup distrobox enter "$CONTAINER" -- bash "$script" </dev/null >"$logfile" 2>&1 &
  echo $! > "$pidfile"
  disown
}

warmup_chat() {
  local prompt="Tu es un assistant de code concis. Explique etape par etape comment implementer une file de priorite (tas binaire) generique en TypeScript avec insert, pop, peek et heapify, en donnant la complexite de chaque operation."
  echo "🌡  Warmup chat ($CHAT_ALIAS) ..."
  if curl -s "http://127.0.0.1:$CHAT_PORT/v1/chat/completions" \
       -H "Content-Type: application/json" \
       -d "{\"model\":\"$CHAT_ALIAS\",\"messages\":[{\"role\":\"user\",\"content\":\"$prompt\"}],\"max_tokens\":64,\"stream\":false}" \
       >/dev/null 2>&1; then
    echo "🌡  Warmup chat terminé ✅"
  else
    echo "🌡  Warmup chat échoué (serveur pas prêt ?) ⚠"
  fi
}

warmup_fim() {
  # Prompt de complétion simple (Qwen2.5-Coder, Python) pour chauffer le modèle.
  local prompt="# Fonction pour calculer la factorielle d'un nombre
def factorial(n):
    if n <= 1:
        return 1
    return n * factorial(n - 1)

# Tester la fonction
print(factorial(5))"

  echo "🌡  Warmup FIM ($FIM_ALIAS) ..."
  if curl -s "http://127.0.0.1:$FIM_PORT/v1/completions" \
       -H "Content-Type: application/json" \
       -d "{\"prompt\":\"$prompt\",\"max_tokens\":32,\"stream\":false}" \
       >/dev/null 2>&1; then
    echo "🌡  Warmup FIM terminé ✅"
  else
    echo "🌡  Warmup FIM échoué ⚠"
  fi
}

start_all() {
  echo "═══ Stack LLM — Qwen3-Coder-Next (chat) + Qwen2.5-Coder-3B (FIM) ═══"

  echo "📦 [1/3] podman start $CONTAINER"
  podman start "$CONTAINER" </dev/null >/dev/null 2>&1 || true

  echo "🧠 [2/3] Qwen3-Coder-Next (GDN) sur :$CHAT_PORT (download auto si absent)..."
  launch_detached "$MAIN_SCRIPT" "$LOGDIR/main.log" "$LOGDIR/main.pid"
  # timeout large : couvre un 1er download complet (~38 Go). Démarrages suivants = quelques s.
  wait_ready "$CHAT_PORT" 3600 "chat" "$LOGDIR/main.pid"

  echo "⚡ [3/3] Qwen2.5-Coder-3B FIM sur :$FIM_PORT (download auto si absent)..."
  launch_detached "$FIM_SCRIPT" "$LOGDIR/fim.log" "$LOGDIR/fim.pid"
  wait_ready "$FIM_PORT" 600 "FIM" "$LOGDIR/fim.pid"

  # Warmup détaché : ne bloque pas, ne pollue pas l'écran.
  setsid bash -c "$(declare -f warmup_chat warmup_fim); \
    CHAT_ALIAS='$CHAT_ALIAS' CHAT_PORT='$CHAT_PORT' FIM_PORT='$FIM_PORT'; \
    warmup_chat; warmup_fim" </dev/null >>"$LOGDIR/warmup.log" 2>&1 &
  disown
  echo "🌡  Warmup lancé en arrière-plan (voir $LOGDIR/warmup.log)"

  echo "═══ Stack prête ═══"
}

status() {
  for p in "$CHAT_PORT" "$FIM_PORT"; do
    if curl -sf "http://127.0.0.1:$p/health" >/dev/null 2>&1; then
      echo "  ✅ port $p"
    else
      echo "  ❌ port $p"
    fi
  done
}

case "$cmd" in
  start)   start_all ;;
  stop)    stop_all ;;
  restart) stop_all; sleep 2; start_all ;;
  status)  status ;;
  logs)    tail -F "$LOGDIR"/*.log ;;
  warmup)  warmup_chat; warmup_fim ;;
  *)       echo "Usage: $0 {start|stop|restart|status|logs|warmup}"; exit 1 ;;
esac
