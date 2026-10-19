#!/usr/bin/env python3
"""
LocalAI gRPC backend for hipEngine (github.com/shisa-ai/hipEngine).

hipEngine is a torch-free, ROCm-native inference engine for AMD RDNA3 (gfx1100 /
gfx1151 Strix Halo). It exposes a small Python API (`from hipengine import LLM,
SamplingParams`) over custom HIP kernels — so it fits LocalAI's Python-backend
pattern exactly the way `vllm/backend.py` wraps the vLLM library. This servicer
mirrors that template: it implements the subset of the Backend gRPC service a
text-generation model needs (Health / LoadModel / Predict / PredictStream /
Status / Free / TokenizeString) and stubs the rest.

Model + quant come from the LocalAI model YAML:
    backend: hipengine
    parameters:
      model: shisa-ai/Qwen3.6-35B-A3B-PARO-packed
    quantization: w4_paro

BLUEPRINT NOTE: hipEngine's exact SamplingParams / stream() signatures may drift;
the mappings below are conservative (only known-safe fields are forwarded) and
marked where they assume the documented API (README: LLM.generate / LLM.stream).
"""
import asyncio
import argparse
import gc
import os
import signal
import sys
from concurrent import futures

import grpc

import backend_pb2
import backend_pb2_grpc

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'common'))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'common'))
from grpc_auth import get_auth_interceptors

# hipEngine's public API. torch-free hot path; import must not pull torch.
from hipengine import LLM, SamplingParams as HipSamplingParams

_ONE_DAY_IN_SECONDS = 60 * 60 * 24
MAX_WORKERS = int(os.environ.get('PYTHON_GRPC_MAX_WORKERS', '1'))

# PredictOptions (proto) -> hipEngine SamplingParams kwarg. Verified against
# hipengine 0.2.2: SamplingParams(max_tokens, temperature, top_p, ignore_eos,
# kv_storage, kv_scale_dtype, kv_scale_granularity). It has NO top_k / seed /
# stop, so those proto fields are intentionally not mapped. _sampling_params
# still drops unknowns defensively in case the signature drifts across versions.
_SAMPLING_MAP = {
    "Tokens": "max_tokens",
    "Temperature": "temperature",
    "TopP": "top_p",
}


class BackendServicer(backend_pb2_grpc.BackendServicer):
    """gRPC servicer implementing the Backend service for hipEngine."""

    def __init__(self):
        self.llm = None

    # --- lifecycle -------------------------------------------------------
    def Health(self, request, context):
        return backend_pb2.Reply(message=bytes("OK", 'utf-8'))

    async def LoadModel(self, request, context):
        model = request.Model
        # Quant is required by hipEngine (e.g. "w4_paro"). Prefer the proto
        # Quantization field; fall back to an Options "quant:VALUE" entry.
        quant = request.Quantization or self._option(request.Options, "quant")
        kwargs = {}
        if quant:
            kwargs["quant"] = quant
        # backend="auto" by default in hipEngine; an explicit override can be
        # passed via Options as "backend:VALUE".
        backend = self._option(request.Options, "backend")
        if backend:
            kwargs["backend"] = backend

        try:
            # LLM(...) loads weights (blocking, ~22s PARO / ~74s GGUF). Run off
            # the event loop so the gRPC server stays responsive.
            loop = asyncio.get_event_loop()
            self.llm = await loop.run_in_executor(
                None, lambda: LLM(model, **kwargs)
            )
        except Exception as err:  # noqa: BLE001 - surface any load failure verbatim
            print(f"hipEngine LoadModel failed: {err!r}", file=sys.stderr)
            return backend_pb2.Result(success=False, message=f"{err!r}")

        print(f"hipEngine model loaded: {model} (quant={quant or 'auto'})", file=sys.stderr)
        return backend_pb2.Result(success=True, message="Model loaded successfully")

    async def Free(self, request, context):
        try:
            if self.llm is not None:
                del self.llm
                self.llm = None
            gc.collect()
            return backend_pb2.Result(success=True, message="Model freed")
        except Exception as err:  # noqa: BLE001
            return backend_pb2.Result(success=False, message=f"{err!r}")

    def Status(self, request, context):
        state = (backend_pb2.StatusResponse.State.READY if self.llm is not None
                 else backend_pb2.StatusResponse.State.UNINITIALIZED)
        return backend_pb2.StatusResponse(state=state, memory=backend_pb2.MemoryUsageData())

    # --- generation ------------------------------------------------------
    async def Predict(self, request, context):
        if self.llm is None:
            context.set_code(grpc.StatusCode.FAILED_PRECONDITION)
            context.set_details("Model not loaded")
            return backend_pb2.Reply()
        sp = self._sampling_params(request)
        prompt = request.Prompt
        try:
            loop = asyncio.get_event_loop()
            outputs = await loop.run_in_executor(
                None, lambda: self.llm.generate([prompt], sp)
            )
            text = self._first_text(outputs)
        except Exception as err:  # noqa: BLE001
            context.set_code(grpc.StatusCode.INTERNAL)
            context.set_details(f"{err!r}")
            return backend_pb2.Reply()
        return backend_pb2.Reply(message=bytes(text, 'utf-8'))

    async def PredictStream(self, request, context):
        if self.llm is None:
            context.set_code(grpc.StatusCode.FAILED_PRECONDITION)
            context.set_details("Model not loaded")
            return
        sp = self._sampling_params(request)
        prompt = request.Prompt
        # hipEngine's LLM.stream() yields token-level output (README). It may be
        # a sync generator; drain it in a thread and hand chunks to asyncio via
        # a queue so we never block the event loop.
        queue: asyncio.Queue = asyncio.Queue()
        loop = asyncio.get_event_loop()
        _DONE = object()

        def _drain():
            try:
                for chunk in self.llm.stream([prompt], sp):
                    loop.call_soon_threadsafe(queue.put_nowait, self._chunk_text(chunk))
            except Exception as err:  # noqa: BLE001
                loop.call_soon_threadsafe(queue.put_nowait, err)
            finally:
                loop.call_soon_threadsafe(queue.put_nowait, _DONE)

        loop.run_in_executor(None, _drain)
        while True:
            item = await queue.get()
            if item is _DONE:
                break
            if isinstance(item, Exception):
                context.set_code(grpc.StatusCode.INTERNAL)
                context.set_details(f"{item!r}")
                return
            if item:
                yield backend_pb2.Reply(message=bytes(item, 'utf-8'))

    async def TokenizeString(self, request, context):
        # hipEngine does not expose a public tokenizer primitive in the torch-
        # free API; report unimplemented rather than guess a token count.
        context.set_code(grpc.StatusCode.UNIMPLEMENTED)
        context.set_details("TokenizeString not supported by hipEngine backend")
        return backend_pb2.TokenizationResponse()

    # --- helpers ---------------------------------------------------------
    @staticmethod
    def _option(options, key):
        """Read 'key:value' or 'key=value' from the repeated Options list."""
        for opt in options:
            for sep in (":", "="):
                if opt.startswith(key + sep):
                    return opt[len(key) + 1:]
        return ""

    def _sampling_params(self, request):
        kwargs = {}
        for field, param in _SAMPLING_MAP.items():
            if hasattr(request, field):
                value = getattr(request, field)
                if value not in (None, 0, [], False, ""):
                    # repeated proto fields arrive as containers; normalise stop
                    if param == "stop":
                        value = list(value)
                    kwargs[param] = value
        # Construct defensively: hipEngine's SamplingParams may not accept every
        # kwarg across versions — drop unknowns and retry with the safe minimum.
        try:
            return HipSamplingParams(**kwargs)
        except TypeError:
            safe = {k: kwargs[k] for k in ("max_tokens", "temperature") if k in kwargs}
            return HipSamplingParams(**safe)

    @staticmethod
    def _first_text(outputs):
        """hipEngine generate() returns a list; element may be str or have .text."""
        if not outputs:
            return ""
        out = outputs[0]
        if isinstance(out, str):
            return out
        return getattr(out, "text", None) or getattr(out, "content", None) or str(out)

    @staticmethod
    def _chunk_text(chunk):
        if chunk is None:
            return ""
        if isinstance(chunk, str):
            return chunk
        # stream() may yield objects carrying content and/or reasoning_content.
        # BLUEPRINT TODO: surface reasoning_content via Reply.chat_deltas so the
        # LocalAI reasoning path (see #10744) carries hipEngine's <think> split.
        return getattr(chunk, "text", None) or getattr(chunk, "content", None) or ""


async def serve(address):
    server = grpc.aio.server(
        migration_thread_pool=futures.ThreadPoolExecutor(max_workers=MAX_WORKERS),
        options=[
            ('grpc.max_message_length', 50 * 1024 * 1024),
            ('grpc.max_send_message_length', 50 * 1024 * 1024),
            ('grpc.max_receive_message_length', 50 * 1024 * 1024),
        ],
        interceptors=get_auth_interceptors(aio=True),
    )
    backend_pb2_grpc.add_BackendServicer_to_server(BackendServicer(), server)
    server.add_insecure_port(address)

    loop = asyncio.get_event_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, lambda: asyncio.ensure_future(server.stop(5)))

    await server.start()
    print("hipEngine backend started. Listening on: " + address, file=sys.stderr)
    await server.wait_for_termination()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Run the hipEngine gRPC backend.")
    parser.add_argument("--addr", default="localhost:50051",
                        help="The address to bind the server to.")
    args = parser.parse_args()
    asyncio.run(serve(args.addr))
