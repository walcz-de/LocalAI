# hipEngine backend for LocalAI

A LocalAI gRPC backend that wraps [hipEngine](https://github.com/shisa-ai/hipEngine)
— a torch-free, ROCm-native LLM inference engine for AMD RDNA3 (gfx1100 /
**gfx1151 Strix Halo**). hipEngine drives custom HIP kernels (`hipblasLt`,
`hipGraph`, AOTriton) directly instead of going through PyTorch or llama.cpp, and
claims a large prefill advantage at long context.

Because hipEngine exposes a small Python API (`from hipengine import LLM,
SamplingParams`), it fits LocalAI's **Python-backend** pattern the same way
`vllm/backend.py` wraps the vLLM library. This backend mirrors that template.

## Status: BLUEPRINT

This directory is a complete, upstream-shaped backend skeleton built as a
walk-through of "prepare + build a LocalAI backend." It is **not** yet a
runtime-verified integration:

- ✅ gRPC servicer (`backend.py`) mirrors the vLLM template; proto stubs generate.
- ✅ Build glue (`install.sh` / `run.sh` / `Makefile` / `requirements*.txt`).
- ✅ Backend-gallery entry drafted (`gallery-entry.yaml`).
- ⏳ Full runtime smoke (LoadModel + Predict) needs the ROCm/hipblas backend
  image, a gfx1100/gfx1151 GPU, and a PARO model — see *Building & testing*.
- 🔧 Assumptions marked `BLUEPRINT` / `TODO` in `backend.py` (hipEngine
  `SamplingParams` / `stream()` signatures, reasoning_content surfacing).

## Implemented gRPC methods

| Method | Behaviour |
|---|---|
| `Health` | returns `OK` |
| `LoadModel` | `hipengine.LLM(Model, quant=…, backend=…)` off the event loop |
| `Predict` | `llm.generate([prompt], SamplingParams)` → text |
| `PredictStream` | `llm.stream([prompt], SamplingParams)` drained via a thread→asyncio queue |
| `Status` | `READY` when a model is loaded, else `UNINITIALIZED` |
| `Free` | drop the model, `gc.collect()` |
| `TokenizeString` | `UNIMPLEMENTED` (no public tokenizer in the torch-free API) |

Everything else in `backend.proto` (image/audio/video/tts/rerank/finetune/…) is
intentionally not implemented — this is a text-generation backend.

## Model YAML

```yaml
name: qwen3.6-paro
backend: hipengine
parameters:
  model: shisa-ai/Qwen3.6-35B-A3B-PARO-packed
quantization: w4_paro
# Optional extras via Options (key:value), e.g. an explicit engine backend:
# options:
#   - backend:auto
```

`quantization` maps to hipEngine's `quant=` (e.g. `w4_paro`). If omitted, an
`options:` entry `quant:VALUE` is used, else hipEngine's default.

## Building & testing

hipEngine requires **Python 3.11+** and ROCm (`libamdhip64.so`) from the hipblas
base image.

```bash
# Install into a managed venv + generate backend_pb2*.py (runProtogen):
BUILD_TYPE=hipblas make -C backend/python/hipengine hipengine

# Unit/smoke test. Health works without a GPU; the load+predict test only runs
# when a model is provided:
HIPENGINE_TEST_MODEL=/models/Qwen3.6-35B-A3B-PARO-packed \
  make -C backend/python/hipengine test
```

To ship it as a pullable backend image, wire `capabilities.amd: rocm-hipengine`
(from `gallery-entry.yaml`) into the backend build matrix and add the drafted
entry to `backend/index.yaml`. That CI step is out of scope for this blueprint.

## Licensing note

hipEngine is **AGPL-3.0**. LocalAI is MIT. LocalAI backends run as separate
processes (their own image, gRPC over a socket), which is the usual way AGPL code
is kept at arm's length from an MIT host — but a real upstream contribution must
confirm this with the LocalAI maintainers before any PR.
