# Best Coding Conf

Stack LLM locale pour le coding avec **Qwen3-Coder-Next** (chat) et **Qwen2.5-Coder-3B** (FIM autocomplétion).

## 📦 Composants

| Rôle                 | Modèle                     | Alias              | Port | Optimisation         |
| -------------------- | -------------------------- | ------------------ | ---- | -------------------- |
| Chat (conversation)  | Qwen3-Coder-Next (MoE GDN) | `qwen3-coder-next` | 8080 | Contexte 262K tokens |
| FIM (autocomplétion) | Qwen2.5-Coder-3B (Q5_K_M)  | `qwen2.5-coder-3b` | 8081 | Contexte 16K tokens  |
