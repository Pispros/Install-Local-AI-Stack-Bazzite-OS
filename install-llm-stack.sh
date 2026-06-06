#!/bin/bash
# Orchestrateur : précharge sur l'hôte, lance les 2 serveurs dans le distrobox, puis warmup.
# Chat = Qwen3-30B-A3B (attention pleine -> KV cache reuse OK, follow-ups rapides).
set -u

LOGDIR="$HOME/llm-logs"
mkdir -p "$LOGDIR"

CONTAINER="llm"
MAIN_SCRIPT="/home/NJMER/start-llm.sh"
FIM_SCRIPT="/home/NJMER/start-llm-fast.sh"

# --- Modèle de chat courant ---------------------------------------------------
# Pour changer de modèle : édite start-llm.sh (--hf-repo/--hf-file/--alias)
# ET mets CHAT_ALIAS à la meme valeur ici.
CHAT_ALIAS="qwen3-30b-a3b"
CHAT_PORT=8080
FIM_PORT=8081
# -----------------------------------------------------------------------------

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

# Lance un script dans le distrobox, totalement détaché du terminal.
# IMPORTANT : on l'invoque via `bash "$script"` (et pas en exécution directe).
# Du coup le bit +x ET le shebang du script deviennent FACULTATIFS : un
# copier-coller qui casse l'un ou l'autre ne pourra plus empêcher le démarrage.
launch_detached() {
  local script=$1 logfile=$2 pidfile=$3
  setsid distrobox enter "$CONTAINER" -- bash "$script" </dev/null >"$logfile" 2>&1 &
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
  echo "🌡  Warmup FIM ..."
  if curl -s "http://127.0.0.1:$FIM_PORT/v1/completions" \
       -H "Content-Type: application/json" \
       -d '{"prompt":"// additionne deux entiers\nfunction add(a: number, b: number): number {\n  return ","max_tokens":32,"stream":false}' \
       >/dev/null 2>&1; then
    echo "🌡  Warmup FIM terminé ✅"
  else
    echo "🌡  Warmup FIM échoué ⚠"
  fi
}

start_all() {
  echo "═══ Stack LLM — Qwen3-30B-A3B (chat) + Coder-1.5B (FIM) ═══"

  echo "📦 [1/4] podman start $CONTAINER"
  podman start "$CONTAINER" </dev/null >/dev/null 2>&1

  echo "🔥 [2/4] Préchargement page cache (hôte)..."
  "$HOME/preload-models.sh" </dev/null

  echo "🧠 [3/4] Qwen3-30B-A3B sur :$CHAT_PORT..."
  launch_detached "$MAIN_SCRIPT" "$LOGDIR/main.log" "$LOGDIR/main.pid"
  wait_ready "$CHAT_PORT" 180 "chat"

  echo "⚡ [4/4] Coder-1.5B FIM sur :$FIM_PORT..."
  launch_detached "$FIM_SCRIPT" "$LOGDIR/fim.log" "$LOGDIR/fim.pid"
  wait_ready "$FIM_PORT" 60 "FIM"

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
