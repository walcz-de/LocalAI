#!/bin/bash
set -e

backend_dir=$(dirname $0)

if [ -d $backend_dir/common ]; then
    source $backend_dir/common/libbackend.sh
else
    source $backend_dir/../common/libbackend.sh
fi

# hipEngine needs Python 3.11+ (README) and ROCm libs (libamdhip64.so) from the
# hipblas base image. installRequirements picks the ${BUILD_TYPE} requirements
# file and runs runProtogen to generate backend_pb2*.py from backend.proto.
if [ "x${BUILD_TYPE}" == "xhipblas" ]; then
    PYTHON_VERSION="3.11"
fi

installRequirements
