# LocalAI Agent Instructions

This file is an index to detailed topic guides in the `.agents/` directory. Read the relevant file(s) for the task at hand — you don't need to load all of them.

## Topics

| File | When to read |
|------|-------------|
| [.agents/building-and-testing.md](.agents/building-and-testing.md) | Building the project, running tests, Docker builds for specific platforms |
| [.agents/adding-backends.md](.agents/adding-backends.md) | Adding a new backend (Python, Go, or C++) — full step-by-step checklist |
| [.agents/coding-style.md](.agents/coding-style.md) | Code style, editorconfig, logging, documentation conventions |
| [.agents/llama-cpp-backend.md](.agents/llama-cpp-backend.md) | Working on the llama.cpp backend — architecture, updating, tool call parsing |
| [.agents/testing-mcp-apps.md](.agents/testing-mcp-apps.md) | Testing MCP Apps (interactive tool UIs) in the React UI |
| [.agents/api-endpoints-and-auth.md](.agents/api-endpoints-and-auth.md) | Adding API endpoints, auth middleware, feature permissions, user access control |
| [.agents/debugging-backends.md](.agents/debugging-backends.md) | Debugging runtime backend failures, dependency conflicts, rebuilding backends |

## Upstream PR Plan (TODO)

Drei fokussierte PRs, saubere Branch von aktuellem `master`:

### PR 1 — gfx1151 / ROCm 7.x GPU Support
- `gfx1151` zu GPU_TARGETS hinzufügen (Dockerfile ARG, Makefile, `.github/workflows/image.yml`)
- ROCm Repo-URL auf `repo.amd.com/rocm/packages/ubuntu2404` aktualisieren
- Neue ROCm 7.x Lib-Pfade: `librocprofiler-register.so*`, `libamd_comgr_loader.so*`, `libamd_comgr.so*`
- `LD_LIBRARY_PATH=/opt/rocm/llvm/lib` für `libamd_comgr` dlopen
- rocWMMA FlashAttention: `-DGGML_HIP_ROCWMMA_FATTN=ON`
- Python Backends: AMD Prerelease Wheels wenn `ROCM_ARCH=gfx1151`
- **NICHT**: `GGML_CUDA_ENABLE_UNIFIED_MEMORY=1` — das gehört nicht rein

### PR 2 — Embedding Dimensions Fix (cherry-pick PR #8809 / commit 77fd096)
- `backend/backend.proto`: Feld `int32 Dimensions = 52` zu PredictOptions
- `core/backend/options.go`: `Dimensions: int32(*c.Dimensions)` in gRPCPredictOpts()
- `make protogen` danach

### PR 3 — Docs
- `docs/content/docs/features/GPU-acceleration.md`: gfx1151 / Strix Halo in verified devices, HSA_OVERRIDE, Kernel-Params

**Vorgehen:**
```bash
git checkout master && git pull upstream master
git checkout -b pr/rocm7-gfx1151-support
# relevante Commits cherry-picken (nicht deployment-spezifisches)
git cherry-pick <sha> ...
```

---

## gfx1151 / Strix Halo Build — Kritische Erkenntnisse

### `rebuild.sh` — Ein-Befehl Build+Deploy
```bash
bash rebuild.sh   # führt Checks, Build, Push, Deploy und Verifikation durch
```

### VRAM-Problem: `GGML_CUDA_ENABLE_UNIFIED_MEMORY`

**NIEMALS setzen** — weder in `Dockerfile`, `docker-compose.yaml`, noch in Model-YAMLs.

Der C-Code prüft `getenv(...) != nullptr` — selbst `=0` aktiviert es, weil die Variable dann **gesetzt** ist.
Effekt wenn gesetzt: `hipMallocManaged` → 32GB System-RAM. Effekt wenn nicht gesetzt: `hipMalloc` → 96GB VRAM.

Verifikation nach Deploy:
```bash
docker exec agntsio-localai-1 env | grep UNIFIED_MEMORY   # muss leer sein
rocm-smi --showmeminfo vram                                # steigt beim Laden auf GB-Bereich
```

### `GGML_HIP_UMA` CMake-Flag existiert nicht mehr
Nur noch Laufzeit-Env-Var `GGML_CUDA_ENABLE_UNIFIED_MEMORY` — aber die soll nicht gesetzt sein (s.o.).

### Model-YAML `env:` Sektionen entfernen
Model-YAMLs in `/opt/agntsio/models/` dürfen keine `env:` Sektionen haben — diese überschreiben die Container-Env.
Nach Gallery-Imports prüfen: `grep -l "^env:" /opt/agntsio/models/*.yaml`

### Doppelte Model-Namen vermeiden
Gallery-Imports erzeugen oft YAML-Dateien mit demselben `name:` wie vorhandene Custom-Configs.
Prüfen: `grep -h "^name:" /opt/agntsio/models/*.yaml | sort | uniq -d`
Gallery-Version löschen, Custom-Config behalten.

### `docker compose restart` vs `--force-recreate`
`restart` behält alte Container-Env-Vars. Bei Änderungen an Image oder Compose immer:
```bash
docker compose up -d localai --force-recreate
```

---

## Quick Reference

- **Logging**: Use `github.com/mudler/xlog` (same API as slog)
- **Go style**: Prefer `any` over `interface{}`
- **Comments**: Explain *why*, not *what*
- **Docs**: Update `docs/content/` when adding features or changing config
- **Build**: Inspect `Makefile` and `.github/workflows/` — ask the user before running long builds
- **UI**: The active UI is the React app in `core/http/react-ui/`. The older Alpine.js/HTML UI in `core/http/static/` is pending deprecation — all new UI work goes in the React UI
