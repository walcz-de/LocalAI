# rocmfp4 patch series

The `rocmfp4` backend reuses `backend/cpp/llama-cpp/grpc-server.cpp` but compiles it against
the walcz-de ROCmFP4 fork. The wrapper Makefile drops the vendored
`backend/cpp/llama-cpp/patches/` before building, so anything the shared server needs on top
of the fork checkout is carried here and applied by `../apply-patches.sh`.

Two kinds of patch belong here:

- **Deliberate reverts we also carry for `llama-cpp`.** These are not fork skew — they are
  behaviour we want on gfx1151 regardless of which backend serves the model, so both
  backends must carry them or the two disagree at runtime.
- **Fork-skew back-ports.** Upstream API changes the shared gRPC server depends on but the
  fork does not yet carry, when the fork sits behind LocalAI's `LLAMA_VERSION` pin.

The second kind should normally be empty: the fork is rebased onto exactly the pin in
`backend/cpp/llama-cpp/Makefile`, which is what makes the `rm -rf patches` in the wrapper
Makefile safe. If a skew patch appears here, the fork has drifted off the pin — rebase it
rather than growing this directory.

Rules:

- One upstream commit (or minimal hunk) per patch, named `NNNN-short-description.patch`.
- Patches are applied with `git apply` from the fork's checkout root.
- `apply-patches.sh` fails fast if a patch stops applying cleanly — that is the signal the
  fork has caught up (or diverged), so re-cut or drop the patch.
- Keep this set as small as possible.

## Current series

- `0001-revert-c7d87229-hip-integrated-crossover.patch` — identical to the `llama-cpp` copy.
  Reverts ggml-org/llama.cpp#25992: `prop.integrated` on HIP iGPUs (gfx1151/UMA) mixes up
  responses across requests under `-np 4 --kv-unified`, which is our standing
  `LLAMACPP_PARALLEL=4` configuration. Drop it here and in `llama-cpp` together, once fixed
  upstream.
