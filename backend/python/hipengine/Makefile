.PHONY: hipengine
hipengine:
	bash install.sh

.PHONY: run
run: hipengine
	@echo "Running hipengine..."
	bash run.sh
	@echo "hipengine run."

.PHONY: test
test: hipengine
	@echo "Testing hipengine..."
	bash test.sh
	@echo "hipengine tested."

.PHONY: protogen-clean
protogen-clean:
	$(RM) backend_pb2_grpc.py backend_pb2.py

.PHONY: clean
clean: protogen-clean
	rm -rf venv __pycache__
