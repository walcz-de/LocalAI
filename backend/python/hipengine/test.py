"""Smoke test for the hipEngine LocalAI backend.

Skips unless HIPENGINE_TEST_MODEL points at a local PARO/GGUF model (needs a
gfx1100/gfx1151 GPU + ROCm). Starts the gRPC server in-process, loads the model,
and runs a single Predict — the minimal end-to-end path.
"""
import os
import subprocess
import time
import unittest

import grpc
import backend_pb2
import backend_pb2_grpc


class TestHipEngineBackend(unittest.TestCase):
    def setUp(self):
        self.model = os.environ.get("HIPENGINE_TEST_MODEL", "")
        self.addr = "localhost:50051"
        self.proc = subprocess.Popen(["python3", "backend.py", "--addr", self.addr])
        time.sleep(10)

    def tearDown(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()

    def test_health(self):
        with grpc.insecure_channel(self.addr) as channel:
            stub = backend_pb2_grpc.BackendStub(channel)
            resp = stub.Health(backend_pb2.HealthMessage())
            self.assertEqual(resp.message, b"OK")

    def test_load_and_predict(self):
        if not self.model:
            self.skipTest("HIPENGINE_TEST_MODEL not set — needs gfx1100/gfx1151 + a PARO model")
        with grpc.insecure_channel(self.addr) as channel:
            stub = backend_pb2_grpc.BackendStub(channel)
            r = stub.LoadModel(backend_pb2.ModelOptions(
                Model=self.model, Quantization="w4_paro"))
            self.assertTrue(r.success, r.message)
            reply = stub.Predict(backend_pb2.PredictOptions(
                Prompt="Reply with the single word: OK", Tokens=8, Temperature=0.0))
            self.assertTrue(len(reply.message) > 0)


if __name__ == "__main__":
    unittest.main()
