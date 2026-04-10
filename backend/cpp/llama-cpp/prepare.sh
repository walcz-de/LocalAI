#!/bin/bash

## Patches

## Apply patches from the `patches` directory
if [ -d "patches" ]; then
    for patch in $(ls patches); do
        echo "Applying patch $patch"
        patch -d llama.cpp/ -p1 < patches/$patch
    done 
fi

set -e

for file in $(ls llama.cpp/tools/server/); do
    cp -rfv llama.cpp/tools/server/$file llama.cpp/tools/grpc-server/
done

cp -r CMakeLists.txt llama.cpp/tools/grpc-server/
cp -r grpc-server.cpp llama.cpp/tools/grpc-server/
cp -rfv llama.cpp/vendor/nlohmann/json.hpp llama.cpp/tools/grpc-server/
cp -rfv llama.cpp/vendor/cpp-httplib/httplib.h llama.cpp/tools/grpc-server/

# Copy common/ headers into the grpc-server staging directory so that
# grpc-server.cpp can include chat-auto-parser.h and its transitive deps
# (chat.h, jinja/caps.h, peg-parser.h, …) directly without relying on cmake
# include-path propagation, which proved fragile across build variants.
cp -f llama.cpp/common/*.h llama.cpp/tools/grpc-server/ 2>/dev/null || true
for _subdir in jinja minja; do
    if [ -d "llama.cpp/common/$_subdir" ]; then
        cp -rf "llama.cpp/common/$_subdir" llama.cpp/tools/grpc-server/
    fi
done
unset _subdir

set +e
if grep -q "grpc-server" llama.cpp/tools/CMakeLists.txt; then
    echo "grpc-server already added"
else
    echo "add_subdirectory(grpc-server)" >> llama.cpp/tools/CMakeLists.txt
fi
set -e

