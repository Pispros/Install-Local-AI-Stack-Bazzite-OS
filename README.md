# Stack LLM locale — UM890 Pro / Bazzite

Installation tout-en-un d'une stack LLM locale sur **Bazzite OS** avec le iGPU **Radeon 780M** (Ryzen 9 8945HS), via une **distrobox Fedora** qui compile `llama.cpp` avec Vulkan.

Deux serveurs tournent en parallèle :

| Service | Modèle                          | Port | Usage             |
|---------|---------------------------------|------|-------------------|
| Chat    | Qwen3.6-35B-A3B (UD-Q4_K_XL)    | 8080 | Conversation, MCP |
| FIM     | Qwen2.5-Coder-3B (Q8_0)         | 8081 | Autocomplétion IDE |

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
   - `llm-stack.sh` — orchestrateur central
6. **Service systemd** — installe `llm-stack.service` (`--user`) pour démarrage auto au login

---

## La GTT (Graphics Translation Table) en pratique

Le iGPU 780M n'a que **1 GiB de VRAM dédiée**. Pour faire tenir un modèle de 21 GiB, il faut élargir la **GTT**, qui mappe de la RAM système comme mémoire GPU. Sur Bazzite (immuable, basé `rpm-ostree`), ça se fait par **kargs** au boot.

### Valeurs appliquées

Le script pose trois kernel arguments :

| Karg                            | Valeur     | Effet                              |
|---------------------------------|------------|------------------------------------|
| `ttm.pages_limit=12582912`      | 48 GiB     | Limite haute du TTM (mémoire GPU)  |
| `ttm.page_pool_size=6291456`    | 24 GiB     | Pool pré-alloué                    |
| `amdgpu.gttsize=49152`          | 48 GiB     | Taille GTT exposée par AMDGPU      |

### Pourquoi 48 GiB sur 64 GiB de RAM ?

- **Modèles chargés** : 21 GiB (chat) + 3 GiB (FIM) + KV cache ≈ 30 GiB
- **Marge GTT** : 48 − 30 = 18 GiB pour les pics
- **Réservé au système** : 64 − 48 = 16 GiB pour le kernel, le DE, les apps, Steam, le page cache

Steam peut utiliser jusqu'à ~30 GiB en pratique pendant un jeu si tu arrêtes la stack LLM (`~/llm-stack.sh stop` libère les ~25 GiB des modèles).

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

## Utilisation quotidienne

```bash
~/llm-stack.sh start      # démarre les deux serveurs (+ warmup)
~/llm-stack.sh stop       # tue les deux serveurs
~/llm-stack.sh restart    # stop + start
~/llm-stack.sh status     # ping /health sur 8080 et 8081
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

Le modèle sera téléchargé automatiquement par llama.cpp depuis Hugging Face au premier lancement.

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

### `Préchargement... introuvable`

Le `find` ne trouve pas le GGUF. Vérifier :

```bash
find ~/.cache/huggingface/hub -iname '*qwen*coder*3b*q8*' 2>/dev/null
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
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
│  ~/.config/systemd/user/llm-stack.service                 │
│       └─ ExecStart=~/llm-stack.sh start (auto au login)   │
│                                                            │
│  Kargs : ttm.pages_limit / amdgpu.gttsize = 48 GiB        │
└─────────────────────────────┬──────────────────────────────┘
                              │
                              ▼  (podman + distrobox)
┌───────────────────────────────────────────────────────────┐
│  Container 'llm' (fedora-toolbox:41)                      │
│    - /dev/dri, /dev/kfd montés                            │
│    - ~/llama.cpp/build/bin/llama-server (Vulkan)          │
│    - vulkan-loader, mesa RADV → 780M                      │
└───────────────────────────────────────────────────────────┘
```

Le container partage le `$HOME` avec l'hôte, donc les scripts dans `~/` sont accessibles des deux côtés sans recopie.
