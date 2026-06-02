# Stack LLM locale — Bazzite

Installation tout-en-un d'une stack LLM locale sur **Bazzite OS** avec le iGPU **Radeon 780M** (Ryzen 9 8945HS), via une **distrobox Fedora** qui compile `llama.cpp` avec Vulkan.

Deux serveurs LLM tournent en parallèle dans la distrobox, plus un conteneur podman dédié à la recherche web :

| Service | Modèle / Image                  | Port | Usage             |
|---------|---------------------------------|------|-------------------|
| Chat    | Qwen3.6-35B-A3B (UD-Q4_K_XL)    | 8080 | Conversation, MCP |
| FIM     | Qwen2.5-Coder-1.5B (Q8_0)       | 8081 | Autocomplétion IDE |
| Search  | open-websearch (MCP)            | 3333 | Recherche web pour la WebUI |

> **Note sur le FIM** : on utilise le **1.5B** et non le 3B. Pour de l'autocomplétion, la contrainte est la latence (la suggestion doit arriver avant que tu tapes le caractère suivant). Sur le 780M, qui est limité par la bande passante mémoire, un 1.5B (~1.7 GiB à relire par token) est ~2× plus rapide qu'un 3B (~3,3 GiB) pour une qualité encore très correcte ligne par ligne. C'est aussi la taille recommandée par les plugins officiels llama.vim/llama.vscode pour une config < 8 GiB de VRAM. Si tu veux encore plus réactif, passe au `Qwen2.5-Coder-0.5B-Q8_0-GGUF` ; si tu veux plus de qualité et que la latence te convient, remonte au 3B.

---

## Installation rapide

```bash
bash install-llm-stack.sh
```

Le script est **idempotent** : tu peux le relancer autant de fois que tu veux. À chaque étape il vérifie l'état avant d'agir.

### Options

```
--skip-kargs    sauter la modification des kargs (déjà fait)
--skip-build    sauter la compilation de llama.cpp (déjà fait)
--status        afficher l'état actuel sans rien modifier
```

### Ce que fait le script

1. **Préflight** — détecte l'OS, vérifie podman/distrobox, RAM, GPU
2. **Kargs GTT** — configure 48 GiB de GTT via `rpm-ostree kargs`
3. **Distrobox** — crée le container `llm` basé sur `fedora-toolbox:41` avec accès `/dev/dri` et `/dev/kfd`, installe les dépendances Vulkan
4. **Compile llama.cpp** — clone le repo et compile avec `-DGGML_VULKAN=ON`
5. **Pose les scripts** dans `~/` :
   - `preload-models.sh` — précharge les GGUF dans le page cache (warm cache → premier prompt rapide)
   - `start-llm.sh` — lance le serveur chat dans la distrobox
   - `start-llm-fast.sh` — lance le serveur FIM dans la distrobox
   - `open-websearch/docker-compose.yaml` — le MCP de recherche web (conteneur podman)
   - `llm-stack.sh` — orchestrateur central (lance/arrête les 2 serveurs **et** le MCP de recherche)
6. **Service systemd** — installe `llm-stack.service` (`--user`) pour démarrage auto au login

---

## La GTT (Graphics Translation Table) en pratique

Le iGPU 780M n'a que **1 GiB de VRAM dédiée** (le *carve-out*). Pour faire tenir un modèle de 21 GiB, il faut élargir la **GTT**, qui mappe de la RAM système comme mémoire GPU. Sur Bazzite (immuable, basé `rpm-ostree`), ça se fait par **kargs** au boot.

### Valeurs appliquées

Le script pose trois kernel arguments :

| Karg                            | Valeur     | Effet                              |
|---------------------------------|------------|------------------------------------|
| `ttm.pages_limit=12582912`      | 48 GiB     | Limite haute du TTM (mémoire GPU)  |
| `ttm.page_pool_size=6291456`    | 24 GiB     | Pool pré-alloué                    |
| `amdgpu.gttsize=49152`          | 48 GiB     | Taille GTT exposée par AMDGPU      |

### Pourquoi 48 GiB sur 64 GiB de RAM ?

- **Modèles chargés** : 21 GiB (chat) + 1,7 GiB (FIM) + KV cache. Le KV cache du chat est lourd à `--ctx-size 138240` (q8_0), donc compte une enveloppe globale de l'ordre de **35–40 GiB** une fois le contexte rempli.
- **Marge GTT** : ce qui reste sous 48 GiB sert aux pics d'allocation.
- **Réservé au système** : 64 − 48 = 16 GiB pour le kernel, le DE, les apps, Steam, le page cache.

Steam peut utiliser une grosse part de la RAM pendant un jeu si tu arrêtes la stack LLM (`~/llm-stack.sh stop` libère les modèles et leur KV cache).

### Vérifier la GTT effective

```bash
# Au boot courant
cat /proc/cmdline | tr ' ' '\n' | grep -E 'gtt|ttm|amdgpu'

# Vue dynamique
cat /sys/class/drm/card*/device/mem_info_gtt_total | numfmt --to=iec
cat /sys/class/drm/card*/device/mem_info_gtt_used  | numfmt --to=iec

# Driver au démarrage
sudo dmesg | grep -i 'GTT memory ready'
```

Cible : `GTT total : 48G` (ou `49152M` dans dmesg).

### Modifier la valeur

Pour pousser à plus (ou réduire), édite les variables en haut du script :

```bash
GTT_PAGES_LIMIT=12582912   # 4 KiB × cette valeur = octets
GTT_POOL_SIZE=6291456
GTT_AMDGPU_SIZE=49152      # en MiB
```

Relance le script (il détectera la nouvelle valeur cible et reprogrammera les kargs), puis reboote.

### Reculer en cas de problème

Si le boot a un souci après modification :

```bash
# Avant reboot — annule le déploiement en attente
sudo rpm-ostree cleanup -p

# Après un boot qui pose problème — rollback au déploiement précédent
sudo rpm-ostree rollback
sudo systemctl reboot
```

---

## Le carve-out VRAM et `RADV_DEBUG=zerovram`

Symptôme historique de cette machine : des performances **instables** (« parfois rapide, parfois ultra lent », sans rapport avec le cold start), et dans les logs de bench des lignes `Failed to allocate ... domains: 2/4`.

**Cause** : le carve-out VRAM du 780M ne fait que **1 GiB**. RADV tente d'allouer des buffers de compute (jusqu'à ~1 GiB) dans cette zone, échoue dès qu'elle est pleine, et retombe sur un fallback sysmem au comportement irrégulier — d'où la variance énorme du débit.

**Correctif** : `RADV_DEBUG=zerovram` dit à RADV d'ignorer ce carve-out d'1 GiB (inutile sur une archi UMA) et de tout router via le **GTT**. Comme VRAM et GTT pointent vers la même RAM physique à la même vitesse, on ne perd rien — on supprime juste le goulot d'allocation. Cette variable est posée dans `start-llm.sh` **et** `start-llm-fast.sh`.

Pour vérifier la taille du carve-out :

```bash
for d in /sys/class/drm/card*/device/mem_info_vram_total; do
  echo "$d : $(awk '{print $1/1048576 " MiB"}' "$d" 2>/dev/null)"
done
# Attendu : 1024 MiB  (c'est normal, zerovram s'en occupe)
```

Si jamais `zerovram` ne suffisait pas (rare), le plan B est d'agrandir le carve-out dans le **BIOS** (« UMA Frame Buffer Size » / « iGPU Memory », mode `UMA_SPECIFIED`) à 4 ou 8 GiB. Mais ça immobilise d'autant la RAM en permanence, alors que `zerovram` est gratuit et réversible — d'où le choix de `zerovram` par défaut.

---

## Mémoire : pas de `--no-mmap --mlock`

Les scripts de lancement **n'utilisent volontairement pas** `--no-mmap` ni `--mlock`.

- `--no-mmap` charge tout le modèle en RAM non réclamable au lieu de le mapper depuis le disque.
- `--mlock` verrouille cette mémoire pour interdire à Linux de l'évincer.

Sur cette archi UMA où le modèle + le KV cache vivent déjà tous en RAM (via le GTT), ces deux options poussent vite à la saturation et au **swap**, qui est *la* cause des ralentissements monstrueux. En laissant `mmap` actif, une grosse part du modèle reste en `buff/cache` réclamable et Linux garde sa marge de manœuvre.

### Le seul critère qui compte : le swap

Une RAM « pleine » n'est **pas** un problème en soi (le `buff/cache` est réclamable). Ce qui compte, c'est que le swap reste à zéro. Pendant un run, dans un autre terminal :

```bash
watch -n1 free -h
```

- `Swap used` à **0** → tout va bien, même si `Mem used` paraît énorme.
- `Swap used` qui monte → réduis `--ctx-size`, ou allège la charge.

Repère validé sur cette machine à `--ctx-size 138240` : `Swap used` ≈ 0, `available` ≈ 27 GiB. Si tu remontes le contexte au-delà, resurveille le swap.

---

## Recherche web via MCP (open-websearch)

La WebUI intégrée de llama.cpp peut appeler des outils externes exposés en **MCP**. On utilise ici **open-websearch**, un serveur MCP multi-moteurs (DuckDuckGo, Bing, Brave…) **sans clé API**, lancé dans son propre conteneur podman sur le port **3333**.

> Le MCP de recherche **ne remplace pas** la WebUI : il se branche *dedans*. Le navigateur (WebUI) atteint le MCP en passant par le **cors-proxy** de llama-server, ce qui évite les soucis de CORS. C'est pour ça que `start-llm.sh` lance le serveur chat avec `--ui-mcp-proxy`.

### Le flag a changé de nom

`--webui-mcp-proxy` est **déprécié** ; le nom courant est **`--ui-mcp-proxy`** (l'ancien reste accepté comme alias). Le script utilise déjà le nouveau. Variable d'env équivalente : `LLAMA_ARG_UI_MCP_PROXY=1`.

### Démarrer le MCP

Il est lancé automatiquement par `~/llm-stack.sh start`. Manuellement :

```bash
podman compose -f ~/open-websearch/docker-compose.yaml up -d
podman compose -f ~/open-websearch/docker-compose.yaml logs -f   # vérifier
curl http://127.0.0.1:3333/mcp                                   # doit répondre
```

> Si `podman compose` n'est pas disponible, installe le plugin : `pip install --user podman-compose` (puis `podman-compose ...`), ou utilise `docker compose` si Docker est présent. Le fichier compose est identique.

### Connecter le MCP dans la WebUI

1. Ouvre la WebUI : `http://127.0.0.1:8080` (serveur chat).
2. Réglages → MCP → ajoute un serveur avec l'URL `http://127.0.0.1:3333/mcp`, puis **SAUVEGARDE**.
3. **Rouvre** la connexion via l'**icône crayon** (edit) — c'est seulement à l'édition qu'apparaît le bouton **« use llama-server proxy »**. Active-le.
4. Les outils de recherche apparaissent alors dans la WebUI ; le modèle peut les appeler (le chat tourne avec `tools: true`).

### Sécurité

Le cors-proxy de llama-server est un **proxy ouvert** (risque de SSRF) et l'option est expérimentale — **à ne pas exposer sur Internet**. Garde la stack sur ton LAN de confiance. Si tu ajoutes une `--api-key`, sache qu'un bug connu fait que la WebUI n'injecte pas la clé dans les requêtes `/cors-proxy` (les connexions MCP échouent en 401) — préfère donc, pour l'instant, ne pas combiner clé API et proxy MCP, ou vérifie que c'est corrigé dans ta version.

### Réseau (distrobox ↔ conteneur search)

Le fetch MCP part de llama-server (dans la distrobox) vers `127.0.0.1:3333`. distrobox partage le réseau de l'hôte, et le conteneur open-websearch mappe `3333` sur l'hôte, donc `127.0.0.1:3333` est joignable des deux côtés. Si un jour tu isoles le réseau de la distrobox, remplace `127.0.0.1` par l'IP LAN de la machine dans l'URL MCP.

---

## Utilisation quotidienne

```bash
~/llm-stack.sh start      # démarre les deux serveurs (+ warmup)
~/llm-stack.sh stop       # tue les deux serveurs
~/llm-stack.sh restart    # stop + start
~/llm-stack.sh status     # ping /health sur 8080 et 8081, + état du conteneur search
~/llm-stack.sh logs       # tail des deux logs

# Via systemd
systemctl --user status llm-stack.service
systemctl --user restart llm-stack.service

# Logs détaillés
tail -f ~/llm-logs/main.log    # serveur chat
tail -f ~/llm-logs/fim.log     # serveur FIM
tail -f ~/llm-logs/warmup.log  # warmup
```

### Tester les endpoints

```bash
# Health
curl -sf http://127.0.0.1:8080/health && echo " ← chat OK"
curl -sf http://127.0.0.1:8081/health && echo " ← FIM OK"

# Chat (OpenAI-compatible)
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.6-a3b","messages":[{"role":"user","content":"Salut"}],"max_tokens":50}'

# FIM (completions)
curl -s http://127.0.0.1:8081/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen-coder-fim","prompt":"def fib(n):\n    if n < 2:\n        return n\n    return ","max_tokens":20}'
```

### Config côté éditeur

Le serveur expose un alias stable (`qwen3.6-a3b` pour le chat, `qwen-coder-fim` pour le FIM), donc la config client ne change pas même si tu remplaces le modèle sous-jacent. Pense juste à aligner le `max_tokens` du client sur le `--ctx-size` du serveur (138240 pour le chat).

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

> L'IP `192.168.0.190` est codée en dur — fige-la (réservation DHCP ou IP statique) sinon l'autocomplétion casse au prochain bail. Si l'éditeur tourne sur la même machine que les serveurs, `127.0.0.1` est plus robuste.

---

## Mise à jour

### Mettre à jour `llama.cpp`

```bash
# Arrête la stack
~/llm-stack.sh stop

# Pull et rebuild dans la distrobox
distrobox enter llm -- bash -c '
  cd ~/llama.cpp
  git pull --rebase
  cmake --build build --config Release -j$(nproc) \
    --target llama-cli llama-server llama-gguf-split
'

# Relance
~/llm-stack.sh start
```

Ou plus simple, relance le script principal sans `--skip-build` :

```bash
bash install-llm-stack.sh --skip-kargs
```

### Mettre à jour Bazzite (l'hôte)

Bazzite se met à jour automatiquement en arrière-plan via `rpm-ostree`. Pour forcer :

```bash
rpm-ostree upgrade
sudo systemctl reboot
```

Les kargs GTT sont préservés à travers les mises à jour rpm-ostree. Si tu veux les vérifier après une grosse mise à jour :

```bash
bash install-llm-stack.sh --status
```

### Mettre à jour Fedora dans la distrobox

```bash
distrobox enter llm -- sudo dnf upgrade -y
```

Reconstruis llama.cpp si l'upgrade a touché Vulkan ou GCC :

```bash
distrobox enter llm -- bash -c 'cd ~/llama.cpp && rm -rf build && cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release && cmake --build build -j$(nproc) --target llama-server'
```

### Changer de modèle

Édite `~/start-llm.sh` ou `~/start-llm-fast.sh`, modifie `--hf-repo` / `--hf-file` (ou `-hf`), puis :

```bash
~/llm-stack.sh restart
```

Le modèle sera téléchargé automatiquement par llama.cpp depuis Hugging Face au premier lancement. Si tu changes le modèle FIM, pense à ajuster aussi le pattern dans `~/preload-models.sh`.

---

## Dépannage

### `Exec format error` dans le log

Le script (start-llm.sh ou start-llm-fast.sh) n'a pas de shebang valide. Vérifier :

```bash
head -1 ~/start-llm-fast.sh | od -c | head -1
```

Tu dois voir `#   !   /   b   i   n   /   b   a   s   h  \n`. Si le `#!` est absent, recrée le script avec un heredoc protégé (`<< 'EOF'` avec quotes).

### `connect to 127.0.0.1 port 808x ... refused`

Le serveur n'écoute pas. Vérifier dans l'ordre :

1. Le process tourne-t-il ? `distrobox enter llm -- pgrep -af llama-server`
2. Le port est-il bind ? `ss -tlnp | grep -E '8080|8081'`
3. Que dit le log ? `tail -n 40 ~/llm-logs/fim.log`

### `Failed to allocate ... domains: 2/4` et débit instable

C'est le symptôme du carve-out VRAM d'1 GiB (voir section dédiée). Vérifie que `RADV_DEBUG=zerovram` est bien présent dans le script de lancement :

```bash
distrobox enter llm -- env | grep RADV_DEBUG    # doit afficher zerovram
grep RADV_DEBUG ~/start-llm.sh ~/start-llm-fast.sh
```

Si la variable est absente, ajoute `export RADV_DEBUG=zerovram` sous `RADV_PERFTEST=gpl` et relance.

### Lenteur / la machine rame, RAM pleine

Vérifie le **swap**, pas la RAM (voir section « Mémoire »). `free -h` : tant que `Swap used` est à 0, la RAM pleine est normale. Si le swap monte, réduis `--ctx-size` côté chat, et assure-toi que `--no-mmap --mlock` n'a pas été réintroduit dans les scripts.

### `Préchargement... introuvable`

Le `find` ne trouve pas le GGUF. Vérifier :

```bash
find ~/.cache/huggingface/hub -iname '*qwen*coder*1.5b*q8*' 2>/dev/null
find ~/.cache/huggingface/hub -iname '*qwen3.6-35b*' 2>/dev/null
```

Si le nom de fichier diffère, ajuste les patterns dans `~/preload-models.sh`.

### La GTT n'est pas à la valeur voulue après reboot

```bash
# Voir le déploiement actif et les kargs
rpm-ostree status
rpm-ostree kargs

# Voir ce que le driver expose réellement
sudo dmesg | grep -i 'GTT memory ready'
```

Si `rpm-ostree kargs` ressort des valeurs avec doublons (`ttm.pages_limit=ttm.pages_limit=...`), c'est un déploiement pending cassé. Nettoie :

```bash
sudo rpm-ostree cleanup -p
bash install-llm-stack.sh   # repose les kargs proprement
```

### Performance dégradée après reboot

Les **shaders Vulkan** sont recompilés au premier prompt après un changement de driver ou de version Mesa. Le `MESA_SHADER_CACHE_DIR` les met en cache pour les boots suivants. Premier prompt lent = normal. Si c'est lent en permanence, vérifie :

```bash
ls -la ~/.cache/mesa_shader_cache/
distrobox enter llm -- env | grep -E 'AMD_VULKAN|RADV'
```

---

## Architecture

```
┌───────────────────────────────────────────────────────────┐
│  Bazzite OS (hôte, immuable)                              │
│                                                            │
│  ┌─── ~/llm-stack.sh (orchestrateur) ──────────────────┐  │
│  │                                                      │  │
│  │  1. preload-models.sh  ← page cache GGUF            │  │
│  │  2. distrobox enter llm -- start-llm.sh    (8080)   │  │
│  │  3. distrobox enter llm -- start-llm-fast.sh (8081) │  │
│  │  4. podman compose up open-websearch       (3333)   │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
│  ~/.config/systemd/user/llm-stack.service                 │
│       └─ ExecStart=~/llm-stack.sh start (auto au login)   │
│                                                            │
│  Kargs : ttm.pages_limit / amdgpu.gttsize = 48 GiB        │
│  RADV_DEBUG=zerovram → tout via GTT (carve-out 1 GiB ignoré) │
└──────────────┬───────────────────────────┬─────────────────┘
               │ (podman + distrobox)       │ (podman)
               ▼                            ▼
┌──────────────────────────────────┐  ┌──────────────────────────┐
│  Container 'llm' (fedora-toolbox) │  │  open-websearch (MCP)    │
│   - /dev/dri, /dev/kfd montés    │  │   :3333  /mcp  /sse      │
│   - llama-server (Vulkan) → 780M │◀─┤   DuckDuckGo/Bing/Brave  │
│   - chat :8080  +  FIM :8081     │  │   (via cors-proxy WebUI) │
│   - --ui-mcp-proxy (chat)        │  └──────────────────────────┘
└──────────────────────────────────┘
```

Le container partage le `$HOME` avec l'hôte, donc les scripts dans `~/` sont accessibles des deux côtés sans recopie.
