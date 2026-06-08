#!/bin/bash
# OPTIONNEL — non appelé par llm-stack.sh (qui fait son propre warmup inline).
# Garde-le seulement si tu veux préchauffer un prompt SYSTÈME stable à la main.
# L'alias doit correspondre à celui de start-llm.sh.
set -u

CHAT_ALIAS="glm-4.7-flash"
SYS_PROMPT_FILE="$HOME/.config/llm/system-prompt.txt"
mkdir -p "$(dirname "$SYS_PROMPT_FILE")"

if [ ! -f "$SYS_PROMPT_FILE" ]; then
  cat > "$SYS_PROMPT_FILE" << 'PROMPT'
You are a helpful coding assistant running locally.
Be concise. Use markdown code blocks for code. Answer in the user's language.
PROMPT
fi

for i in $(seq 1 60); do
  curl -sf http://127.0.0.1:8080/health >/dev/null 2>&1 && break
  sleep 1
done

SYS=$(jq -Rs . < "$SYS_PROMPT_FILE")

echo "[$(date +%H:%M:%S)] warmup chat (port 8080)..."
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${CHAT_ALIAS}\",\"messages\":[{\"role\":\"system\",\"content\":${SYS}},{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1,\"cache_prompt\":true}" \
  > /dev/null

echo "[$(date +%H:%M:%S)] warmup FIM (port 8081)..."
curl -s http://127.0.0.1:8081/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen-coder-fim","prompt":"def hello():","max_tokens":1,"cache_prompt":true}' \
  > /dev/null

echo "[$(date +%H:%M:%S)] warmup done"
