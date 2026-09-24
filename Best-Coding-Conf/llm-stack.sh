#!/bin/bash
# Orchestrateur : (re)lance / arrête / vérifie les serveurs dans le distrobox.
# Le TÉLÉCHARGEMENT des modèles est géré par les scripts start-* (download-if-missing).
#
# Chat = Qwen3-Coder-Next (MoE qwen3_next / Gated DeltaNet). Quant choisi dans start-llm.sh
#        (HF_MODEL). Pour revenir au Q4 : mettre ...GGUF:UD-Q4_K_XL dans start-llm.sh.
#   ⚠ GDN : reprocessing complet du prompt à chaque tour (pas de KV reuse propre) -> follow-ups lents.
# FIM  = Qwen2.5-Coder-3B (Q5_K_M), autocomplétion. MAINTENANT OPT-IN (voir cibles ci-dessous).
#
# ── Cibles (2e argument, optionnel) ───────────────────────────────────────────
#   chat  : agit sur le serveur chat uniquement
#   fim   : agit sur le serveur FIM uniquement
#   all   : agit sur les deux
#   (vide): défaut = chat pour start/restart/warmup ; all pour stop/status/logs
#
# Exemples :
#   ./llm-stack.sh start          # chat Q4 seul (FIM PAS lancé)
#   ./llm-stack.sh restart        # redémarre le chat, ne touche pas à FIM
#   ./llm-stack.sh stop fim       # arrête FIM et ne le relance pas
#   ./llm-stack.sh start all      # chat + FIM (si tu veux ravoir l'autocomplétion)
# ──────────────────────────────────────────────────────────────────────────────
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
target="${2:-}"

# Résout la cible effective selon la commande quand aucune n'est fournie.
resolve_target() {
  local c=$1 t=$2
  if [ -n "$t" ]; then echo "$t"; return; fi
  case "$c" in
    stop|status|logs) echo "all" ;;   # nettoyage / visibilité : tout par défaut
    *)                echo "chat" ;;   # start/restart/warmup : chat seul par défaut
  esac
}

# ── Bas niveau ────────────────────────────────────────────────────────────────

wait_ready() {
  local port=$1 timeout=$2 label=$3 pidfile=${4:-}
  echo -n "    Attente $label (port $port)"
  local i=0
  while true; do
    if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      echo " — prêt en ${i}s ✅"; return 0
    fi
    if [ -n "$pidfile" ] && [ -f "$pidfile" ] && ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      echo " ❌ process terminé (voir log)"; return 1
    fi
    i=$((i+1))
    if [ "$i" -ge "$timeout" ]; then echo " ❌ timeout"; return 1; fi
    echo -n "."; sleep 1
  done
}

# Lance un script dans le distrobox, totalement détaché du terminal.
launch_detached() {
  local script=$1 logfile=$2 pidfile=$3
  setsid nohup distrobox enter "$CONTAINER" -- bash "$script" </dev/null >"$logfile" 2>&1 &
  echo $! > "$pidfile"
  disown
}

# Arrêt ciblé par port (le cmdline du llama-server contient "--port <n>").
stop_one() {
  local label=$1 port=$2 pidfile=$3
  echo "⏹  Arrêt $label (port $port)..."
  distrobox enter "$CONTAINER" -- pkill -f "port $port" </dev/null 2>/dev/null || true
  sleep 1
  distrobox enter "$CONTAINER" -- pkill -9 -f "port $port" </dev/null 2>/dev/null || true
  rm -f "$pidfile"
}

# Arrêt total (les deux d'un coup) : balayage large.
stop_all() {
  echo "⏹  Arrêt de tous les serveurs..."
  distrobox enter "$CONTAINER" -- pkill -f "llama-server" </dev/null 2>/dev/null || true
  sleep 2
  distrobox enter "$CONTAINER" -- pkill -9 -f "llama-server" </dev/null 2>/dev/null || true
  rm -f "$LOGDIR"/*.pid
  echo "✅ Arrêté"
}

# ── Warmups ───────────────────────────────────────────────────────────────────

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

# ── Services ──────────────────────────────────────────────────────────────────

start_chat() {
  echo "🧠 Qwen3-Coder-Next (chat) sur :$CHAT_PORT (download auto si absent)..."
  launch_detached "$MAIN_SCRIPT" "$LOGDIR/main.log" "$LOGDIR/main.pid"
  # timeout large : couvre un 1er download complet. Démarrages suivants = quelques s.
  wait_ready "$CHAT_PORT" 3600 "chat" "$LOGDIR/main.pid"
}

start_fim() {
  echo "⚡ Qwen2.5-Coder-3B (FIM) sur :$FIM_PORT (download auto si absent)..."
  launch_detached "$FIM_SCRIPT" "$LOGDIR/fim.log" "$LOGDIR/fim.pid"
  wait_ready "$FIM_PORT" 600 "FIM" "$LOGDIR/fim.pid"
}

stop_chat() { stop_one "chat" "$CHAT_PORT" "$LOGDIR/main.pid"; }
stop_fim()  { stop_one "FIM"  "$FIM_PORT" "$LOGDIR/fim.pid"; }

status_one() {
  local port=$1 label=$2
  if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
    echo "  ✅ $label (port $port)"
  else
    echo "  ❌ $label (port $port)"
  fi
}

# Warmup détaché des services demandés (ne bloque pas l'écran).
warmup_bg() {
  local t=$1
  (
    case "$t" in
      chat) warmup_chat ;;
      fim)  warmup_fim ;;
      all)  warmup_chat; warmup_fim ;;
    esac
  ) >>"$LOGDIR/warmup.log" 2>&1 &
  disown
  echo "🌡  Warmup lancé en arrière-plan (voir $LOGDIR/warmup.log)"
}

# ── Dispatch haut niveau ──────────────────────────────────────────────────────

do_start() {
  local t=$1
  echo "═══ Stack LLM — cible: $t ═══"
  echo "📦 podman start $CONTAINER"
  podman start "$CONTAINER" </dev/null >/dev/null 2>&1 || true
  case "$t" in
    chat) start_chat ;;
    fim)  start_fim ;;
    all)  start_chat; start_fim ;;
    *)    echo "Cible inconnue: $t (chat|fim|all)"; exit 1 ;;
  esac
  warmup_bg "$t"
  [ "$t" = "chat" ] && echo "ℹ  FIM non lancé. Pour l'ajouter : ./llm-stack.sh start all"
  echo "═══ Stack prête ═══"
}

do_stop() {
  local t=$1
  case "$t" in
    chat) stop_chat ;;
    fim)  stop_fim ;;
    all)  stop_all ;;
    *)    echo "Cible inconnue: $t (chat|fim|all)"; exit 1 ;;
  esac
}

do_restart() {
  local t=$1
  do_stop "$t"
  sleep 2
  do_start "$t"
}

do_status() {
  local t=$1
  case "$t" in
    chat) status_one "$CHAT_PORT" "chat" ;;
    fim)  status_one "$FIM_PORT"  "FIM" ;;
    all)  status_one "$CHAT_PORT" "chat"; status_one "$FIM_PORT" "FIM" ;;
  esac
}

do_logs() {
  local t=$1
  case "$t" in
    chat) tail -F "$LOGDIR/main.log" ;;
    fim)  tail -F "$LOGDIR/fim.log" ;;
    all)  tail -F "$LOGDIR"/*.log ;;
  esac
}

do_warmup() {
  local t=$1
  case "$t" in
    chat) warmup_chat ;;
    fim)  warmup_fim ;;
    all)  warmup_chat; warmup_fim ;;
  esac
}

t="$(resolve_target "$cmd" "$target")"

case "$cmd" in
  start)   do_start   "$t" ;;
  stop)    do_stop    "$t" ;;
  restart) do_restart "$t" ;;
  status)  do_status  "$t" ;;
  logs)    do_logs    "$t" ;;
  warmup)  do_warmup  "$t" ;;
  *) echo "Usage: $0 {start|stop|restart|status|logs|warmup} [chat|fim|all]"; exit 1 ;;
esac
