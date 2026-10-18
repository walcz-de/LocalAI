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

None. The fork sits on the `llama-cpp` pin and carries everything the shared server needs.

(Retired: `0001-revert-c7d87229-hip-integrated-crossover.patch` when upstream reverted c7d87229
itself — see the `llama-cpp` pin bump of 2026-09-12; `0002-kolibri1-architecture.patch` when
llama.cpp added Kolibri-1 support itself, ggml-org/llama.cpp#30673. Kolibri GGUFs converted with
the community patch carry `tokenizer.ggml.pre = kolibri1`; upstream maps Kolibri-1 to `qwen2`, so
such a model needs `overrides: ["tokenizer.ggml.pre=str:qwen2"]` in its model config.)
