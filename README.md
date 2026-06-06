# Local LLM stack — Bazzite

All-in-one install of a local LLM stack on **Bazzite OS** using the **Radeon 780M** iGPU (Ryzen 9 8945HS), via a **Fedora distrobox** that builds `llama.cpp` with Vulkan.

Two LLM servers run in parallel inside the distrobox, plus a dedicated podman container for web search:

| Service | Model / Image                     | Port | Use                       |
|---------|-----------------------------------|------|---------------------------|
| Chat    | Qwen3-30B-A3B (UD-Q4_K_XL)        | 8080 | Conversation, MCP         |
| FIM     | Qwen2.5-Coder-1.5B (Q8_0)         | 8081 | IDE autocomplete          |
| Search  | open-websearch (MCP)              | 3333 | Web search for the WebUI  |

> **Why Qwen3-30B-A3B and not Qwen3.6-35B-A3B?** The 3.6/3.5 "A3B" models use a **hybrid GatedDeltaNet attention** (linear attention + recurrent state). On `llama.cpp` that **breaks KV-cache reuse**: the backend silently disables prefix reuse and **re-processes the whole prompt on every request**, which kills multi-turn latency (each follow-up re-reads the full system prompt + history). Qwen3-30B-A3B uses **standard full attention**, so the cache is reused — in the logs you see `selected slot by LCP similarity, sim_best = 0.9xx`, and follow-ups only pay for the delta. That single change is what fixed the "slow follow-ups" problem; the throughput drop that remains as context grows is pure memory bandwidth, not a broken cache.

> **Note on FIM**: we use the **1.5B**, not the 3B. For autocomplete the binding constraint is latency (the suggestion must land before you type the next character). On the 780M, which is memory-bandwidth bound, a 1.5B (~1.7 GiB to re-read per token) is ~2x faster than a 3B (~3.3 GiB) for still-decent line-by-line quality. It's also the size recommended by the official llama.vim/llama.vscode plugins for a < 8 GiB VRAM setup. Want it even snappier, go to `Qwen2.5-Coder-0.5B-Q8_0-GGUF`; want more quality and the latency is fine, go back up to the 3B.

---

## Quick install

```bash
bash install-llm-stack.sh
```

The script is **idempotent**: re-run it as many times as you like. Each step checks state before acting.

### Options

```
--skip-kargs    skip the kargs modification (already done)
--skip-build    skip the llama.cpp build (already done)
--status        show current state without changing anything
```

### What the script does

1. **Preflight** — detects OS, checks podman/distrobox, RAM, GPU
2. **GTT kargs** — configures 48 GiB of GTT via `rpm-ostree kargs`
3. **Distrobox** — creates the `llm` container based on `fedora-toolbox:41` with `/dev/dri` and `/dev/kfd` access, installs the Vulkan dependencies
4. **Builds llama.cpp** — clones the repo and builds with `-DGGML_VULKAN=ON`
5. **Lays down the scripts** in `~/`:
   - `preload-models.sh` — preloads the GGUFs into the page cache (warm cache -> fast first prompt)
   - `start-llm.sh` — launches the chat server in the distrobox
   - `start-llm-fast.sh` — launches the FIM server in the distrobox
   - `open-websearch/docker-compose.yaml` — the web-search MCP (podman container)
   - `llm-stack.sh` — central orchestrator (starts/stops both servers **and** the search MCP, then runs the warmup)
6. **systemd service** — installs `llm-stack.service` (`--user`) for auto start at login

---

## Thinking mode (chat)

Qwen3-30B-A3B is a **hybrid thinking model**: most of its real intelligence on non-trivial tasks (code, multi-step reasoning) lives *inside* the `<think>` trace it emits before answering. **Disabling thinking makes it noticeably dumber.**

- **Default here: thinking ON.** `start-llm.sh` carries **no** `--reasoning-budget` flag, so the server default (`-1` = unlimited) applies. Do **not** pass `--reasoning off` (it disables thinking; the log will show `init: chat template, thinking = 0`).
- **Verify the state**: in `~/llm-logs/main.log` after load, look for `init: chat template, thinking = 1`. In the WebUI, a "Thinking" block before the answer means it's active.
- **Per-request control**: because no budget is fixed on the command line, you can drive it per call with `"thinking_budget_tokens": N` in the request body (only works when no server-side budget is set).
- **Latency knob**: thinking adds generated tokens, and on this bandwidth-bound iGPU generation slows as context grows (see Memory). If responses drag, **don't** turn thinking off — **cap** it: add `--reasoning-budget 4096` (generous; avoid very tight budgets, they can hurt quality more than they help).

### Sampling (must match the mode)

The script uses Qwen's official **thinking-mode** sampling:

```
--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0
```

Do **not** reuse the non-thinking profile (`--temp 0.7 --top-p 0.8`) with thinking on, and **do not** set a high `--presence-penalty` (e.g. 1.5): it makes the model avoid tokens it should produce and degrades answers. Presence penalty is left at the default (0). If you ever switch to non-thinking, use `--temp 0.7 --top-p 0.8`.

---

## Context size (`--ctx-size 138240`) and the model cap

The chat server is launched with `--ctx-size 138240`.

> **Important — this model caps at 40960.** Qwen3-30B-A3B's native trained context (`max_position_embeddings`) is **40960** tokens. `llama.cpp` therefore **caps the slot to the training context**: in `main.log` you'll see
> `the slot context (138240) exceeds the training context of the model (40960) - capping`, then `new slot, n_ctx = 40960`.
> So with the default flags, the effective context is **40960** regardless of the `138240` you ask for, and the KV cache is allocated for 40960 (not 138240) — which is also why setting 138240 is cheap here, it doesn't reserve a 7 GiB buffer.

### To actually use more than 40960 (YaRN)

If you genuinely need long context, enable RoPE scaling explicitly:

```
-c 131072 --rope-scaling yarn --rope-scale 4 --yarn-orig-ctx 32768
```

Caveat (Qwen's own guidance): **static YaRN degrades short-context quality** (occasional looping, weaker reasoning). Enable it only when you actually need the long window — ideally on a **second instance** on another port for "big context" sessions, leaving the main one at native 40960. On this iGPU the prefill of a full long context is also very slow (tens of seconds to minutes), so prefer the agent strategies below over brute-forcing context.

### Handling many / large files without a giant window

For "read dozens of files" or files of 2000+ lines (one such file is already ~15-25k tokens), don't stuff the window:
- Let the editor's agent **search the codebase on the fly** (grep/regex) and read only what's relevant, instead of @-mentioning everything.
- @-mention **symbols** or selections, not whole large files.
- Use **subagents** (separate context windows) to investigate, returning only a summary to the main thread.
- Start a fresh thread per task so history doesn't accumulate.
- For genuinely huge one-shot jobs, point the editor at a **cloud provider** for that task and keep the local model for fast inline work.

---

## The GTT (Graphics Translation Table) in practice

The 780M iGPU only has **1 GiB of dedicated VRAM** (the *carve-out*). To fit an ~18 GiB model you have to widen the **GTT**, which maps system RAM as GPU memory. On Bazzite (immutable, `rpm-ostree`-based) this is done via boot **kargs**.

### Applied values

The script sets three kernel arguments:

| Karg                            | Value      | Effect                             |
|---------------------------------|------------|------------------------------------|
| `ttm.pages_limit=12582912`      | 48 GiB     | TTM upper limit (GPU memory)       |
| `ttm.page_pool_size=6291456`    | 24 GiB     | Pre-allocated pool                 |
| `amdgpu.gttsize=49152`          | 48 GiB     | GTT size exposed by AMDGPU         |

### Why 48 GiB out of 64 GiB of RAM?

- **Loaded models**: ~18 GiB (chat, Qwen3-30B-A3B UD-Q4_K_XL) + ~1.7 GiB (FIM 1.5B) + KV cache. With the chat context capped to 40960, the KV cache (q8_0) is only a couple of GiB, so the overall envelope sits around **22-25 GiB** once context fills. (If you enable YaRN to 131072, the KV grows to ~7 GiB and the envelope to ~30 GiB — re-check swap then.)
- **GTT headroom**: whatever's left under 48 GiB absorbs allocation spikes.
- **Reserved for the system**: 64 - 48 = 16 GiB for the kernel, the DE, apps, Steam, the page cache.

Steam can use a large share of RAM during a game if you stop the LLM stack (`~/llm-stack.sh stop` frees the models and their KV cache).

### Check the effective GTT

```bash
# On the current boot
cat /proc/cmdline | tr ' ' '\n' | grep -E 'gtt|ttm|amdgpu'

# Dynamic view
cat /sys/class/drm/card*/device/mem_info_gtt_total | numfmt --to=iec
cat /sys/class/drm/card*/device/mem_info_gtt_used  | numfmt --to=iec

# Driver at boot
sudo dmesg | grep -i 'GTT memory ready'
```

Target: `GTT total : 48G` (or `49152M` in dmesg).

### Change the value

To push higher (or lower), edit the variables at the top of the script:

```bash
GTT_PAGES_LIMIT=12582912   # 4 KiB x this value = bytes
GTT_POOL_SIZE=6291456
GTT_AMDGPU_SIZE=49152      # in MiB
```

Re-run the script (it detects the new target and reprograms the kargs), then reboot.

### Rolling back if something breaks

If the boot has an issue after a change:

```bash
# Before reboot — cancel the pending deployment
sudo rpm-ostree cleanup -p

# After a problematic boot — roll back to the previous deployment
sudo rpm-ostree rollback
sudo systemctl reboot
```

---

## The VRAM carve-out and `RADV_DEBUG=zerovram`

Historical symptom on this machine: **unstable** performance ("sometimes fast, sometimes very slow", unrelated to cold start), and in bench logs lines like `Failed to allocate ... domains: 2/4`.

**Cause**: the 780M VRAM carve-out is only **1 GiB**. RADV tries to allocate compute buffers (up to ~1 GiB) in that zone, fails as soon as it fills up, and falls back to sysmem with irregular behavior — hence the huge throughput variance.

**Fix**: `RADV_DEBUG=zerovram` tells RADV to ignore that 1 GiB carve-out (useless on a UMA architecture) and route everything via the **GTT**. Since VRAM and GTT point to the same physical RAM at the same speed, you lose nothing — you just remove the allocation bottleneck. This variable is set in `start-llm.sh` **and** `start-llm-fast.sh`.

To check the carve-out size:

```bash
for d in /sys/class/drm/card*/device/mem_info_vram_total; do
  echo "$d : $(awk '{print $1/1048576 " MiB"}' "$d" 2>/dev/null)"
done
# Expected: 1024 MiB  (that's normal, zerovram takes care of it)
```

If `zerovram` ever isn't enough (rare), the plan B is to grow the carve-out in the **BIOS** ("UMA Frame Buffer Size" / "iGPU Memory", `UMA_SPECIFIED` mode) to 4 or 8 GiB. But that permanently reserves that much RAM, whereas `zerovram` is free and reversible — hence `zerovram` as the default.

---

## Memory: no `--no-mmap --mlock`

The launch scripts **deliberately do not use** `--no-mmap` or `--mlock`.

- `--no-mmap` loads the whole model into non-reclaimable RAM instead of mapping it from disk.
- `--mlock` locks that memory so Linux can't evict it.

On this UMA architecture, where the model + KV cache already all live in RAM (via the GTT), these two options push you fast toward saturation and **swap**, which is *the* cause of the monster slowdowns. Leaving `mmap` active keeps a large chunk of the model in reclaimable `buff/cache` and gives Linux its breathing room.

### The only criterion that matters: swap

A "full" RAM is **not** a problem in itself (`buff/cache` is reclaimable). What matters is that swap stays at zero. During a run, in another terminal:

```bash
watch -n1 free -h
```

- `Swap used` at **0** -> all good, even if `Mem used` looks huge.
- `Swap used` climbing -> reduce the effective context (or enable YaRN only when needed), or lighten the load.

With the 30B at the native 40960 context, expect generous headroom (`Swap used` ~ 0, `available` comfortably above 30 GiB). If you enable YaRN to 131072, re-watch swap.

### Throughput vs context (the real ceiling)

On the 780M, generation is **memory-bandwidth bound**, so token rate falls as the KV cache grows. Observed on a real session: ~30 t/s at ~2k of context, decaying to ~17-20 t/s past ~25k, with prompt-eval (prefill) dropping from ~320 t/s to ~80 t/s over the same range. This is physics, not a bug. Practical consequences: keep sessions reasonably short, and cap thinking if latency bites. On this hardware you effectively pick **two of {smart, fast, long-context}** — bandwidth is the wall.

---

## Web search via MCP (open-websearch)

llama.cpp's built-in WebUI can call external tools exposed over **MCP**. Here we use **open-websearch**, a multi-engine MCP server (DuckDuckGo, Bing, Brave...) **without an API key**, running in its own podman container on port **3333**.

> The search MCP **does not replace** the WebUI: it plugs *into* it. The browser (WebUI) reaches the MCP through llama-server's **cors-proxy**, which avoids CORS issues. That's why `start-llm.sh` launches the chat server with `--ui-mcp-proxy`.

### The flag name

`--webui-mcp-proxy` is the **deprecated** spelling; the current name is **`--ui-mcp-proxy`** (the old one still works as an alias, so a script carrying `--webui-mcp-proxy` keeps working). Equivalent env var: `LLAMA_ARG_UI_MCP_PROXY=1`.

> The periodic `http client error: Failed to read connection` lines in `main.log` paired with `proxying GET request to http://localhost:3333/mcp` are **cosmetic** — they're just the MCP SSE stream closing and reconnecting, not a model crash.

### Start the MCP

It's launched automatically by `~/llm-stack.sh start`. Manually:

```bash
podman compose -f ~/open-websearch/docker-compose.yaml up -d
podman compose -f ~/open-websearch/docker-compose.yaml logs -f   # check
curl http://127.0.0.1:3333/mcp                                   # should respond
```

> If `podman compose` isn't available, install the plugin: `pip install --user podman-compose` (then `podman-compose ...`), or use `docker compose` if Docker is present. The compose file is identical.

### Connect the MCP in the WebUI

1. Open the WebUI: `http://127.0.0.1:8080` (chat server).
2. Settings -> MCP -> add a server with URL `http://127.0.0.1:3333/mcp`, then **SAVE**.
3. **Reopen** the connection via the **pencil (edit) icon** — the **"use llama-server proxy"** toggle only shows up on edit. Enable it.
4. The search tools then appear in the WebUI; the model can call them (chat runs with `tools: true`).

### Security

llama-server's cors-proxy is an **open proxy** (SSRF risk) and the option is experimental — **do not expose it to the internet**. Keep the stack on a trusted LAN. If you add an `--api-key`, note that a known bug means the WebUI doesn't inject the key into `/cors-proxy` requests (MCP connections fail with 401) — so for now don't combine an API key with the MCP proxy, or verify it's fixed in your version.

### Networking (distrobox <-> search container)

The MCP fetch originates from llama-server (inside the distrobox) toward `127.0.0.1:3333`. distrobox shares the host network, and the open-websearch container maps `3333` on the host, so `127.0.0.1:3333` is reachable from both sides. If you ever isolate the distrobox network, replace `127.0.0.1` with the machine's LAN IP in the MCP URL.

---

## Daily use

```bash
~/llm-stack.sh start      # start both servers (+ warmup)
~/llm-stack.sh stop       # kill both servers
~/llm-stack.sh restart    # stop + start
~/llm-stack.sh status     # ping /health on 8080 and 8081, + search container state
~/llm-stack.sh logs       # tail both logs
~/llm-stack.sh warmup     # re-run the warmup manually

# Via systemd
systemctl --user status llm-stack.service
systemctl --user restart llm-stack.service

# Detailed logs
tail -f ~/llm-logs/main.log    # chat server
tail -f ~/llm-logs/fim.log     # FIM server
tail -f ~/llm-logs/warmup.log  # warmup
```

> The orchestrator launches the in-distrobox servers fully detached from the terminal (`setsid ... </dev/null` + `disown`). This is what stops `llama-server`'s loading bar / HF download progress from leaking onto your shell and leaving it choppy or frozen. If a terminal ever gets garbled, `reset` (or `stty sane`) fixes it.

### Test the endpoints

```bash
# Health
curl -sf http://127.0.0.1:8080/health && echo " <- chat OK"
curl -sf http://127.0.0.1:8081/health && echo " <- FIM OK"

# Chat (OpenAI-compatible)
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-30b-a3b","messages":[{"role":"user","content":"Hi"}],"max_tokens":50}'

# FIM (completions)
curl -s http://127.0.0.1:8081/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen-coder-fim","prompt":"def fib(n):\n    if n < 2:\n        return n\n    return ","max_tokens":20}'

# Search MCP reachable
curl -s http://127.0.0.1:3333/mcp
```

### Editor config

The server exposes a stable alias (`qwen3-30b-a3b` for chat, `qwen-coder-fim` for FIM), so the client config doesn't change even if you swap the underlying model.

```json
"edit_predictions": {
  "provider": "open_ai_compatible_api",
  "open_ai_compatible_api": {
    "api_url": "http://192.168.0.190:8081/v1/completions",
    "model": "qwen-coder-fim",
    "prompt_format": "qwen",
    "max_output_tokens": 256
  }
}
```

> The IP `192.168.0.190` is hard-coded — pin it (DHCP reservation or static IP) or autocomplete breaks at the next lease. If the editor runs on the same machine as the servers, `127.0.0.1` is more robust.

---

## Updating

### Update `llama.cpp`

```bash
# Stop the stack
~/llm-stack.sh stop

# Pull and rebuild in the distrobox
distrobox enter llm -- bash -c '
  cd ~/llama.cpp
  git pull --rebase
  cmake --build build --config Release -j$(nproc) \
    --target llama-cli llama-server llama-gguf-split
'

# Restart
~/llm-stack.sh start
```

Or simpler, re-run the main script without `--skip-build`:

```bash
bash install-llm-stack.sh --skip-kargs
```

### Update Bazzite (the host)

Bazzite updates automatically in the background via `rpm-ostree`. To force it:

```bash
rpm-ostree upgrade
sudo systemctl reboot
```

GTT kargs are preserved across rpm-ostree updates. To verify after a big update:

```bash
bash install-llm-stack.sh --status
```

### Update Fedora inside the distrobox

```bash
distrobox enter llm -- sudo dnf upgrade -y
```

Rebuild llama.cpp if the upgrade touched Vulkan or GCC:

```bash
distrobox enter llm -- bash -c 'cd ~/llama.cpp && rm -rf build && cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release && cmake --build build -j$(nproc) --target llama-server'
```

### Change model

Edit `~/start-llm.sh` or `~/start-llm-fast.sh`, change `--hf-repo` / `--hf-file` (or `-hf`), then:

```bash
~/llm-stack.sh restart
```

The model is downloaded automatically by llama.cpp from Hugging Face on first launch. **No change needed in `preload-models.sh`**: it now reads `--hf-file` directly from the launch scripts and resolves the real blob in the HF cache, so the preloader always follows the model you actually run (this is what fixed the bug where it kept preloading the old 35B blob and reported the FIM "not found").

> If you ever want to trade up on agentic coding / tool-use specifically, **GLM-4.7-Flash** (30B-A3B, MLA attention) is the strongest drop-in: MLA keeps the cache reuse intact *and* the KV ~4x smaller, so it decays less in throughput at high context. Just change `--hf-repo`/`--hf-file`/`--alias` in `start-llm.sh` (use **f16** KV with it, not q8_0), then restart and verify cache reuse in the log.

---

## Troubleshooting

### `Exec format error` in the log

The script (start-llm.sh or start-llm-fast.sh) has no valid shebang. Check:

```bash
head -1 ~/start-llm-fast.sh | od -c | head -1
```

You should see `#   !   /   b   i   n   /   b   a   s   h  \n`. If `#!` is missing, recreate the script with a quoted heredoc (`<< 'EOF'`).

### Model "too dumb" / weak on code & reasoning

Thinking is probably disabled. Check `~/llm-logs/main.log` for `init: chat template, thinking = 0`. Remove any `--reasoning off` / `--reasoning-budget 0` from `start-llm.sh`, make sure the sampling is the thinking profile (`--temp 0.6 --top-p 0.95`) and that `--presence-penalty` isn't set high, then restart. See the "Thinking mode" section.

### `connect to 127.0.0.1 port 808x ... refused`

The server isn't listening. Check in order:

1. Is the process running? `distrobox enter llm -- pgrep -af llama-server`
2. Is the port bound? `ss -tlnp | grep -E '8080|8081'`
3. What does the log say? `tail -n 40 ~/llm-logs/fim.log`

### `Failed to allocate ... domains: 2/4` and unstable throughput

This is the 1 GiB VRAM carve-out symptom (see dedicated section). Verify `RADV_DEBUG=zerovram` is present in the launch script:

```bash
distrobox enter llm -- env | grep RADV_DEBUG    # should print zerovram
grep RADV_DEBUG ~/start-llm.sh ~/start-llm-fast.sh
```

If it's missing, add `export RADV_DEBUG=zerovram` under `RADV_PERFTEST=gpl` and restart.

### Slow / machine struggling, RAM full

Check **swap**, not RAM (see "Memory" section). `free -h`: as long as `Swap used` is 0, full RAM is normal. If swap climbs, reduce the effective context on chat, and make sure `--no-mmap --mlock` wasn't reintroduced into the scripts.

### Slow follow-ups / "re-processing the whole prompt"

If the log shows `forcing full prompt re-processing due to lack of cache data` on every turn, the model has **hybrid/SWA/recurrent attention** and KV-cache reuse is unsupported — that's the Qwen3.5/3.6-A3B family. Switch back to a **full-attention** model (Qwen3-30B-A3B, or GLM-4.7-Flash with MLA). With a working setup you should instead see `selected slot by LCP similarity, sim_best = 0.9xx`.

### Web search MCP not working

```bash
# Is the container up?
podman ps --format '{{.Names}}' | grep open-websearch
podman logs --tail 40 open-websearch

# Is the endpoint reachable from the host?
curl -s http://127.0.0.1:3333/mcp
```

If the container is up but the WebUI shows nothing: re-check that you toggled "use llama-server proxy" via the pencil (edit) icon, and that chat was started with `--ui-mcp-proxy`.

### `Preloading... not found`

The new `preload-models.sh` reads `--hf-file` from the launch scripts and resolves the blob automatically, so this should be rare. If it still warns, the filename in the launch script doesn't match anything in the cache. List what's actually there:

```bash
find ~/.cache/huggingface/hub -iname '*.gguf' | sed 's#.*/##' | sort -u
```

and make sure the `--hf-file` in `start-llm.sh` / `start-llm-fast.sh` matches one of them.

### Reclaim space from the old 35B

If you migrated from Qwen3.6-35B-A3B, its ~21 GiB blob is still in the cache. Remove it:

```bash
rm -rf ~/.cache/huggingface/hub/models--unsloth--Qwen3.6-35B-A3B-GGUF
```

### GTT isn't at the expected value after reboot

```bash
# See the active deployment and kargs
rpm-ostree status
rpm-ostree kargs

# See what the driver actually exposes
sudo dmesg | grep -i 'GTT memory ready'
```

If `rpm-ostree kargs` shows duplicated values (`ttm.pages_limit=ttm.pages_limit=...`), it's a broken pending deployment. Clean up:

```bash
sudo rpm-ostree cleanup -p
bash install-llm-stack.sh   # re-lay the kargs cleanly
```

### Degraded performance after reboot

The **Vulkan shaders** are recompiled on the first prompt after a driver or Mesa version change. `MESA_SHADER_CACHE_DIR` caches them for subsequent boots. A slow first prompt is normal. If it's permanently slow, check:

```bash
ls -la ~/.cache/mesa_shader_cache/
distrobox enter llm -- env | grep -E 'AMD_VULKAN|RADV'
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
|  |  2. distrobox enter llm -- start-llm.sh    (8080)   |  |
|  |  3. distrobox enter llm -- start-llm-fast.sh (8081) |  |
|  |  4. podman compose up open-websearch       (3333)   |  |
|  |  5. warmup (detached, background)                   |  |
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
|   - --ui-mcp-proxy (chat)          |  +--------------------------+
+------------------------------------+
```

The container shares `$HOME` with the host, so the scripts in `~/` are accessible from both sides without copying.
