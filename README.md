# Local LLM stack — Bazzite OS

Local **chat + code-autocomplete + web-search** on Bazzite, running `llama.cpp` (Vulkan) inside a Fedora **distrobox** (`llm`). The chat server runs in a **bubblewrap** sandbox nested in the box.

| Service         | Model                              | Port        |
| --------------- | ---------------------------------- | ----------- |
| Chat (+ vision) | Qwen3.5-35B-A3B · UD-Q4\_K\_XL     | 8080        |
| FIM             | DeepSeek-Coder-V2-Lite · Q5\_K\_M  | 8081        |
| Search          | SearXNG + mcp-searxng              | 8888 / 3333 |

## Install — plug and play

```bash
git clone https://github.com/Pispros/Install-Local-AI-Stack-Bazzite-OS
cd Install-Local-AI-Stack-Bazzite-OS
./init.sh
```

`init.sh` does everything: installs the scripts in `~/`, creates the `llm` distrobox (GPU passthrough), **builds `llama.cpp` with Vulkan at `~/llama.cpp/build`**, and prepares the bubblewrap working dir `~/All/llm-working-dir`. All script paths derive from `$HOME`, so they are already correct for your machine — nothing to edit by hand.

Requires `distrobox` + `podman` on the host (Bazzite: `ujust install-distrobox`).

## Run

```bash
bash ~/llm-stack.sh start      # first run downloads the models (chat ~21 GB)
bash ~/llm-stack.sh status     # ✅ 8080  ✅ 8081
bash ~/llm-stack.sh stop|restart|logs
```

> Always drive the stack through `llm-stack.sh` — never `start-llm.sh` directly (it only execs `llama-server` and will clash on port 8080).

## Web search (optional)

`init.sh` writes `searxng/settings.yml` (with a random `secret_key`) and `searxng/tavily.py`. Just set your Tavily key — either re-run with `TAVILY_API_KEY=tvly-... ./init.sh`, or edit `searxng/settings.yml` — then:

```bash
podman compose -f SearXNG-compose.yml up -d
```

In the WebUI add `http://localhost:3333/mcp`, **save**, reopen via the pencil, enable **"use llama-server proxy"**.

## Files

| File                  | Role                                                                      |
| --------------------- | ------------------------------------------------------------------------- |
| `init.sh`             | One-shot installer: distrobox + Vulkan build + working dir + scripts.     |
| `llm-stack.sh`        | Orchestrator: `start` / `stop` / `restart` / `status` / `logs` / `warmup`.|
| `start-llm.sh`        | Chat server (8080), bubblewrap jail nested in the `llm` distrobox.         |
| `start-llm-fast.sh`   | FIM server (8081).                                                         |
| `preload-models.sh`   | Preloads the `.gguf` files into the host page cache before launch.         |
| `warmup-llm.sh`       | Optional manual warmup (not called by `llm-stack.sh`).                     |
| `SearXNG-compose.yml` | SearXNG metasearch + `mcp-searxng` HTTP MCP server.                        |

## Good to know

- `RADV_DEBUG=zerovram` (set in both start scripts) routes all GPU allocs via the GTT — required on the 780M's 1 GiB VRAM carve-out.
- The scripts omit `--no-mmap`/`--mlock` on purpose. Watch swap: `watch -n1 free -h` — keep it at 0, lower `--ctx-size` if it climbs.
- Change the chat model: edit `--hf-repo`/`--hf-file`/`--alias` (or the local `-m` path) in `start-llm.sh`, then set the same `CHAT_ALIAS` in `llm-stack.sh` and restart.
