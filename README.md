# Local LLM stack — Radeon 780M / Bazzite OS

Local **chat + code-autocomplete + web-search** for the Radeon 780M iGPU on Bazzite, running `llama.cpp` (Vulkan) inside a Fedora **distrobox** (`llm`). The chat server runs in a **bubblewrap** sandbox nested in the box.

> ## ⚠️ READ THIS FIRST — the paths are hard-coded to another machine
>
> The scripts ship with the author's home baked in as `/home/xxx`. **Nothing will start until it becomes YOUR `$HOME`.** The one that bites everyone is the **`llama-server` binary path**, and it lives in **two** files:
>
> | File                | Line to fix                                                    |
> | ------------------- | ------------------------------------------------------------- |
> | **`start-llm.sh`**      | `LLAMA_DIR="/home/xxx/llama.cpp/build"`  → your build dir      |
> | **`start-llm-fast.sh`** | `exec /home/xxx/llama.cpp/build/bin/llama-server`  → your path |
>
> ✅ **`./init.sh` rewrites all of these for you** — just run it and you never touch a path by hand. Only edit manually if you skip `init.sh`.

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

`init.sh` does it all: creates the `llm` distrobox (GPU passthrough), **builds `llama.cpp` with Vulkan at `~/llama.cpp/build`**, installs the scripts in `~/`, **rewrites every hard-coded `/home/...` path to your `$HOME`**, and prepares the bubblewrap working dir `~/All/llm-working-dir`.

Requires `distrobox` + `podman` on the host (Bazzite: `ujust install-distrobox`).

## Run

```bash
bash ~/llm-stack.sh start      # first run downloads the models (chat ~21 GB)
bash ~/llm-stack.sh status     # ✅ 8080  ✅ 8081
bash ~/llm-stack.sh stop|restart|logs
```

> Always drive the stack through `llm-stack.sh` — never `start-llm.sh` directly (it only execs `llama-server` and will clash on port 8080).

## Paths to your username (already handled by `init.sh`)

If you set things up by hand, change the **`llama-server` binary path** in **both** launch scripts:

- **`start-llm.sh`** → `LLAMA_DIR="/home/<you>/llama.cpp/build"`  *(used as `"$LLAMA_DIR/bin/llama-server"`)*
- **`start-llm-fast.sh`** → `exec /home/<you>/llama.cpp/build/bin/llama-server`

Other `/home/...` spots `init.sh` also rewrites: `WORK_DIR` and `--ui-config-file` in `start-llm.sh`; `MAIN_SCRIPT` / `FIM_SCRIPT` in `llm-stack.sh`. Keep aliases in sync — chat `qwen3.5-35b-a3b` (`start-llm.sh` ↔ `CHAT_ALIAS`), FIM `deepseek-coder-q5` (`start-llm-fast.sh` ↔ `FIM_ALIAS`).

## Web search (optional)

Add `searxng/settings.yml` (with your Tavily key) and `searxng/tavily.py`, then `podman compose -f SearXNG-compose.yml up -d`. In the WebUI add `http://localhost:3333/mcp`, **save**, reopen via the pencil, enable **"use llama-server proxy"**.

## Good to know

- `RADV_DEBUG=zerovram` (set in both start scripts) routes all GPU allocs via the GTT — required on the 780M's 1 GiB VRAM carve-out.
- The scripts omit `--no-mmap`/`--mlock` on purpose. Watch swap: `watch -n1 free -h` — keep it at 0, lower `--ctx-size` if it climbs.
