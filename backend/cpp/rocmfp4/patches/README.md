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

- `0002-kolibri1-architecture.patch` — Kolibri-1 (Aleph Alpha, `kolibri1`) support, the C++ part of
  the community patch shipped with the Kolibri-1 GGUF (Apache-2.0). Not fork skew and not a revert:
  a new model architecture upstream does not carry yet (feature request ggml-org/llama.cpp#29922).
  Drop it once llama.cpp supports `kolibri1` and the fork is rebased onto that pin.

(The former `0001-revert-c7d87229-hip-integrated-crossover.patch` was retired when upstream
reverted c7d87229 itself — see the `llama-cpp` pin bump of 2026-09-12.)

