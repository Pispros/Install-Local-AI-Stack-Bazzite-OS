# Local LLM stack — Bazzite Os

All-in-one local LLM stack on **Bazzite OS** using the **Radeon 780M** iGPU (Ryzen 9 8945HS), via a **Fedora distrobox** (`llm`) that builds `llama.cpp` with **Vulkan/RADV**. Orchestrated from the host by `llm-stack.sh`.

Two `llama-server` instances run in parallel inside the distrobox, plus a dedicated podman container for web search:

| Service | Model / Image                | Quant      | Port | Use                      |
|---------|------------------------------|------------|------|--------------------------|
| Chat    | Qwen3-30B-A3B                | UD-Q4_K_XL | 8080 | Conversation, MCP        |
| FIM     | Qwen2.5-Coder-1.5B           | Q8_0       | 8081 | IDE autocomplete         |
| Search  | open-websearch (MCP)         | —          | 3333 | Web search for the WebUI |

> **Chat = Qwen3-30B-A3B** (MoE, full attention). Deliberate choice: unlike a hybrid-attention model, the KV cache is reusable, so **follow-ups within a conversation stay fast**. Only the very first message of a new conversation pays the cost of the client's large system prompt (cold start) — see *Warmup*.
>
> **FIM = Coder-1.5B** (*base* model, not Instruct). For autocomplete the constraint is latency, not size: the suggestion must arrive before you type the next character. Alternatives if needed: **0.5B** (even lower latency, weaker) or **3B** (better, slower).

---

## Quick start

Scripts already in `~/`? Make them executable, enable the service, and launch:

```bash
chmod +x ~/start-llm.sh ~/start-llm-fast.sh ~/preload-models.sh ~/llm-stack.sh ~/warmup-llm.sh
systemctl --user enable --now llm-stack.service   # auto-start at login + start now
sudo loginctl enable-linger "$USER"               # keep running without an open session
bash ~/llm-stack.sh status                         # expect ✅ port 8080 and ✅ port 8081
```

No systemd unit yet? Start the stack directly:

```bash
chmod +x ~/*.sh
bash ~/llm-stack.sh start
bash ~/llm-stack.sh status
```

> First boot downloads the GGUF files and compiles Vulkan shaders, so the first `start` is slow. Watch progress with `bash ~/llm-stack.sh logs`.

---

## Quick install

```bash
bash install-llm-stack.sh
```

The script is **idempotent**: re-run it as often as you like. Each step checks state before acting.

### Options

```
--skip-kargs    skip the kargs change (already done)
--skip-build    skip building llama.cpp (already done)
--status        show current state without changing anything
```

### What it does

1. Lays down the GTT kargs (48 GiB) so the iGPU can address enough RAM.
2. Creates the `llm` Fedora distrobox with `/dev/dri` + `/dev/kfd`.
3. Builds `llama.cpp` with the Vulkan backend.
4. Installs the stack scripts in `~/`.
5. Installs and enables the `llm-stack.service` systemd --user unit.

---

## Files

All in `~` (`/home/NJMER`):

| File                 | Role                                                                       |
|----------------------|----------------------------------------------------------------------------|
| `llm-stack.sh`       | Host orchestrator. `start`/`stop`/`restart`/`status`/`logs`/`warmup`.      |
| `start-llm.sh`       | Launches the **chat** server (8080) inside the distrobox.                  |
| `start-llm-fast.sh`  | Launches the **FIM** server (8081) inside the distrobox.                   |
| `preload-models.sh`  | Preloads the `.gguf` files into the host page cache before launch.         |
| `warmup-llm.sh`      | **Optional**, not called by `llm-stack.sh` (which warms up inline).        |

---

## Usage

```bash
bash ~/llm-stack.sh start      # podman start + preload + chat + FIM + warmup
bash ~/llm-stack.sh status     # ✅/❌ for ports 8080 and 8081
bash ~/llm-stack.sh restart    # stop then start
bash ~/llm-stack.sh stop       # kill llama-server inside the distrobox
bash ~/llm-stack.sh logs       # tail -F of ~/llm-logs/*.log
bash ~/llm-stack.sh warmup     # re-run the warmup by hand
```

Logs: `~/llm-logs/main.log` (chat), `~/llm-logs/fim.log` (FIM), `~/llm-logs/warmup.log`.

### Auto-start (systemd --user)

`llm-stack.service` starts the stack at login:

```bash
systemctl --user enable --now llm-stack.service
systemctl --user status llm-stack.service
sudo loginctl enable-linger "$USER"   # start without an open session
```

---

## Changing the chat model

The preloader and orchestrator **follow the model declared in the launch script** — no hard-coded names. To switch:

1. Edit `start-llm.sh`: `--hf-repo`, `--hf-file`, `--alias`.
2. Set `CHAT_ALIAS` to the **same** value in `llm-stack.sh` (used by the warmup).
3. `bash ~/llm-stack.sh restart`.

`preload-models.sh` reads `--hf-file` (chat) and also accepts the short form `-hf repo[:file]` (FIM), then resolves the real blob in the HF cache.

---

## Robustness (launch)

`llm-stack.sh` launches each server via **`bash "$script"`** (not direct execution). As a result the **`+x` bit** *and* the **shebang** are **optional** — a paste that breaks either one can no longer stop the stack from starting.

Launch is also detached from the terminal (`setsid` + `</dev/null` + log redirection + `disown`), so `llama-server`'s progress bar and any HF download neither pollute nor block the terminal.

---

## Warmup

On `start`, once both servers answer `/health`, a background warmup fires one chat request and one FIM request. This warms the **engine**: first-call Vulkan/Mesa shader compilation, model in page cache, prefill path primed.

Honest limit: this generic warmup **cannot** preheat the client-specific large system prompt (Zed/WebUI). The first-message cold start of a conversation therefore remains; to kill it you'd capture and replay that exact prompt (see `warmup-llm.sh`, which primes a stable system prompt).

---

## The VRAM carve-out and `RADV_DEBUG=zerovram`

**Cause of throughput variance:** the 780M VRAM carve-out is only **1 GiB**. RADV tries to allocate compute buffers in that zone, fails as it fills, and falls back to sysmem with irregular behavior.

**Fix:** `RADV_DEBUG=zerovram` tells RADV to ignore that 1 GiB carve-out (useless on a UMA architecture) and route everything via the **GTT**. VRAM and GTT point to the same physical RAM at the same speed, so you lose nothing and remove the bottleneck. Set in `start-llm.sh` **and** `start-llm-fast.sh`.

Check the carve-out size:

```bash
for d in /sys/class/drm/card*/device/mem_info_vram_total; do
  echo "$d : $(awk '{print $1/1048576 " MiB"}' "$d" 2>/dev/null)"
done
# Expected: 1024 MiB  (normal — zerovram handles it)
```

Plan B (rare): grow the carve-out in the **BIOS** ("UMA Frame Buffer Size" / `UMA_SPECIFIED`) to 4–8 GiB. That permanently reserves RAM, whereas `zerovram` is free and reversible — hence it's the default.

---

## Memory: no `--no-mmap --mlock`

The launch scripts **deliberately omit** `--no-mmap` and `--mlock`.

- `--no-mmap` loads the whole model into non-reclaimable RAM instead of mapping it from disk.
- `--mlock` locks that memory so Linux can't evict it.

On this UMA architecture (model + KV cache already live in RAM via the GTT), these push you toward saturation and **swap** — *the* cause of the monster slowdowns. Leaving `mmap` active keeps much of the model in reclaimable `buff/cache`.

### The only criterion that matters: swap

A "full" RAM is **not** a problem (`buff/cache` is reclaimable). What matters is swap staying at zero. During a run:

```bash
watch -n1 free -h
```

- `Swap used` at **0** → fine, even if `Mem used` looks huge.
- `Swap used` climbing → lower `--ctx-size`, or lighten the load.

Validated baseline at `--ctx-size 138240`: `Swap used` ~ 0, `available` ~ 27 GiB. Push context higher → re-watch swap.

---

## Web search via MCP (open-websearch)

llama.cpp's built-in WebUI can call external tools over **MCP**. Here: **open-websearch**, a multi-engine MCP server (DuckDuckGo, Bing, Brave…) **with no API key**, in its own podman container on port **3333**.

> The search MCP **does not replace** the WebUI — it plugs into it. The browser reaches the MCP through llama-server's **cors-proxy**, avoiding CORS issues. That's why the chat server is launched with the UI MCP proxy enabled.

### Flag name

The canonical flag is **`--ui-mcp-proxy`** (what `start-llm.sh` uses). `--webui-mcp-proxy` is the **deprecated alias** — still accepted, since the server routes on `ui_mcp_proxy || webui_mcp_proxy`. Env equivalent: `LLAMA_ARG_UI_MCP_PROXY=1`.

> ⚠️ The rename is recent. If your `llama-server` was built **before** it, only `--webui-mcp-proxy` exists and `--ui-mcp-proxy` will error. Check your build:
>
> ```bash
> distrobox enter llm -- /home/NJMER/llama.cpp/build/bin/llama-server --help 2>&1 | grep -i mcp-proxy
> ```
>
> If only the `--webui` form shows up, either keep it or rebuild llama.cpp to move to the new name.

To connect in the WebUI: add the `/mcp` URL as an MCP server, **save** it, reopen via the pencil/edit icon, then toggle **"use llama-server proxy"** (the toggle only appears after re-opening — known UX trap).

---

## Troubleshooting

| Symptom (in `main.log` or at startup)          | Cause                                                      | Fix                                                                  |
|------------------------------------------------|------------------------------------------------------------|----------------------------------------------------------------------|
| `exec: Exec format error`                      | Missing/garbled `#!/bin/bash` on line 1 of the script      | Rewrite via `cat > … << 'EOF'`; launched through `bash` now           |
| `OCI permission denied … not executable`       | Script lost its `+x` bit (direct execution)                | `chmod +x ~/*.sh` (and `bash "$script"` makes this non-blocking)      |
| `⚠ FIM (?) introuvable en cache`               | Old preloader didn't parse the short `-hf` form            | Fixed: `preload-models.sh` handles `--hf-file` **and** `-hf`          |
| `❌ port 8080` (startup timeout)               | Chat server didn't come up                                 | `tail -n 40 ~/llm-logs/main.log` for the real error                  |
| `Failed to allocate` / wild throughput variance| 1 GiB VRAM carve-out filling up                            | Ensure `RADV_DEBUG=zerovram` is set in both launch scripts           |
| Slowdowns, RAM full, swap rising               | `mmap` disabled / context too large                        | Keep `mmap` on; lower `--ctx-size`; `watch -n1 free -h`              |
| Terminal stuck in "broken" mode after a run    | TTY left in raw mode by a progress bar                     | `reset` or `stty sane`; mitigated by `setsid` detachment            |
| Degraded perf after reboot                     | Vulkan shaders recompiled after a driver/Mesa change       | Normal first prompt; check `~/.cache/mesa_shader_cache/`            |

Check that thinking is active on the chat server:

```bash
grep "thinking =" ~/llm-logs/main.log
```

---

## Architecture

```
+-----------------------------------------------------------+
|  Bazzite OS (host, immutable)                             |
|                                                           |
|  +-- ~/llm-stack.sh (orchestrator) --------------------+  |
|  |                                                     |  |
|  |  1. preload-models.sh  <- page cache GGUF           |  |
|  |  2. distrobox enter llm -- bash start-llm.sh  (8080)|  |
|  |  3. distrobox enter llm -- bash start-llm-fast (8081)| |
|  |  4. podman compose up open-websearch       (3333)   |  |
|  +-----------------------------------------------------+  |
|                                                           |
|  ~/.config/systemd/user/llm-stack.service                 |
|       +- ExecStart=~/llm-stack.sh start (auto at login)   |
|                                                           |
|  Kargs : ttm.pages_limit / amdgpu.gttsize = 48 GiB        |
|  RADV_DEBUG=zerovram -> all via GTT (1 GiB carve-out off) |
+--------------+----------------------------+---------------+
               | (podman + distrobox)       | (podman)
               v                            v
+------------------------------------+  +--------------------------+
|  Container 'llm' (fedora-toolbox)  |  |  open-websearch (MCP)    |
|   - /dev/dri, /dev/kfd mounted     |  |   :3333  /mcp  /sse      |
|   - llama-server (Vulkan) -> 780M  |<-|   DuckDuckGo/Bing/Brave  |
|   - chat :8080  +  FIM :8081       |  |   (via WebUI cors-proxy) |
|   - UI MCP proxy (chat)            |  +--------------------------+
+------------------------------------+
```

The container shares `$HOME` with the host, so the scripts in `~/` are reachable from both sides without copying.
