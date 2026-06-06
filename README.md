# Stack LLM locale — UM890 Pro / Bazzite

Stack LLM locale sur **Bazzite OS**, iGPU **Radeon 780M** (Ryzen 9 8945HS), via une **distrobox Fedora** (`llm`) qui compile `llama.cpp` avec **Vulkan/RADV**. Orchestrée depuis l'hôte par `llm-stack.sh`.

Deux serveurs `llama-server` tournent en parallèle dans la distrobox :

| Service | Modèle                         | Quant      | Port | Usage              |
|---------|--------------------------------|------------|------|--------------------|
| Chat    | Qwen3-30B-A3B                  | UD-Q4_K_XL | 8080 | Conversation, MCP  |
| FIM     | Qwen2.5-Coder-1.5B             | Q8_0       | 8081 | Autocomplétion IDE |

> **Chat = Qwen3-30B-A3B** (MoE, attention pleine). C'est volontaire : contrairement à un modèle à attention hybride, le KV cache est réutilisable, donc **les follow-ups d'une conversation restent rapides**. Seul le tout premier message d'une nouvelle conversation paie le coût du gros prompt système du client (cold start) — voir « Warmup ».
>
> **FIM = Coder-1.5B** (modèle *base*, pas Instruct) : pour l'autocomplétion la contrainte est la latence, pas la taille. La suggestion doit arriver avant la frappe suivante.

---

## Fichiers

Tous dans `~` (`/home/NJMER`) :

| Fichier              | Rôle                                                                              |
|----------------------|-----------------------------------------------------------------------------------|
| `llm-stack.sh`       | Orchestrateur (hôte). `start`/`stop`/`restart`/`status`/`logs`/`warmup`.          |
| `start-llm.sh`       | Lance le serveur **chat** (8080) dans la distrobox.                               |
| `start-llm-fast.sh`  | Lance le serveur **FIM** (8081) dans la distrobox.                                |
| `preload-models.sh`  | Précharge les `.gguf` en page cache de l'hôte avant le démarrage des serveurs.    |
| `warmup-llm.sh`      | **Optionnel**, non appelé par `llm-stack.sh` (qui fait son warmup en interne).    |

---

## Utilisation

```bash
bash ~/llm-stack.sh start      # podman start + preload + chat + FIM + warmup
bash ~/llm-stack.sh status     # ✅/❌ pour 8080 et 8081
bash ~/llm-stack.sh restart    # stop puis start
bash ~/llm-stack.sh stop       # tue les llama-server dans la distrobox
bash ~/llm-stack.sh logs       # tail -F des logs (~/llm-logs/*.log)
bash ~/llm-stack.sh warmup     # relance le warmup à la main
```

Logs : `~/llm-logs/main.log` (chat), `~/llm-logs/fim.log` (FIM), `~/llm-logs/warmup.log`.

### Démarrage automatique (systemd --user)

Le service `llm-stack.service` lance la stack au login :

```bash
systemctl --user enable --now llm-stack.service
systemctl --user status llm-stack.service
```

(Au besoin, `sudo loginctl enable-linger "$USER"` pour que ça démarre sans session ouverte.)

---

## Changer de modèle de chat

Le préchargeur et l'orchestrateur **suivent automatiquement** le modèle déclaré dans le script de lancement. Pour basculer :

1. Édite `start-llm.sh` : `--hf-repo`, `--hf-file`, `--alias`.
2. Mets `CHAT_ALIAS` à la **même** valeur dans `llm-stack.sh` (utilisé pour le warmup).
3. `bash ~/llm-stack.sh restart`.

`preload-models.sh` n'a **aucun nom de modèle en dur** : il lit `--hf-file` (chat) et accepte aussi la forme courte `-hf repo[:file]` (FIM), puis résout le blob réel dans le cache HF.

---

## Robustesse (lancement)

`llm-stack.sh` lance chaque serveur via **`bash "$script"`** (pas en exécution directe). Conséquence : le **bit `+x`** *et* le **shebang** des scripts sont **facultatifs** — un copier-coller qui en casse un ne peut plus empêcher le démarrage.

Le lancement est aussi détaché du terminal (`setsid` + `</dev/null` + redirection des logs + `disown`), donc la barre de progression de `llama-server` et un éventuel téléchargement HF ne polluent ni ne bloquent le terminal.

---

## Warmup

Au `start`, après que les deux serveurs répondent sur `/health`, un warmup en arrière-plan envoie une requête chat et une requête FIM. Ça réchauffe le **moteur** : compilation des shaders Vulkan/Mesa au premier appel, modèle en page cache, chemin prefill amorcé.

Limite honnête : ce warmup générique **ne peut pas** préchauffer le gros prompt système spécifique de ton client (Zed/WebUI). Le cold start du premier message d'une conversation reste donc présent ; pour l'éliminer il faudrait capturer puis rejouer ce prompt exact (cf. `warmup-llm.sh`, qui amorce un prompt système stable).

---

## Mémoire GPU (GTT)

Le 780M partage la RAM. Pour charger le 30B-A3B + son contexte, les kargs réservent ~48 GiB de GTT au iGPU. Si tu reconstruis le système ou changes ces kargs, un **reboot** est nécessaire pour qu'ils prennent effet, puis relance `~/llm-stack.sh start`.

---

## Dépannage

| Symptôme (dans `main.log` ou au démarrage)      | Cause                                                        | Fix                                                                 |
|-------------------------------------------------|--------------------------------------------------------------|---------------------------------------------------------------------|
| `exec: Exec format error`                       | Shebang `#!/bin/bash` manquant/cassé en 1re ligne du script  | Réécrire le script (`cat > … << 'EOF'`) ; lancé via `bash` désormais |
| `OCI permission denied … not executable`        | Script sans bit `+x` (exécution directe)                     | `chmod +x ~/*.sh` (et `bash "$script"` rend ça non bloquant)         |
| `⚠ FIM (?) introuvable en cache`                | Ancien préchargeur ne lisait pas `-hf` (forme courte)        | Corrigé : `preload-models.sh` gère `--hf-file` **et** `-hf`          |
| `❌ port 8080` (timeout au démarrage)            | Le chat n'a pas démarré                                      | `tail -n 40 ~/llm-logs/main.log` pour la vraie erreur               |
| Terminal en mode « cassé » après un run         | TTY mis en raw par la barre de progression                   | `reset` ou `stty sane` ; déjà mitigé par le détachement `setsid`    |

Vérifier que le thinking est actif côté chat :

```bash
grep "thinking =" ~/llm-logs/main.log
```
