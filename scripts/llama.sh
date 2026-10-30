#!/usr/bin/env bash

# Set split args for ampere
SPLIT_ARGS=""
if [ -n "${SPLIT_MODE:-}" ]; then
    SPLIT_ARGS="--split-mode ${SPLIT_MODE} --tensor-split ${TENSOR_SPLIT:-1,1} --fit off"
fi

# Run apptainer
apptainer exec --nv \
    --net --network none \
    --bind ${MODEL_DIR}:/models:ro \
    --bind ${LLM_SOCKET_DIR}:/run/llm:rw \
    --bind ${PWD}/llama:/opt/scripts:ro \
    --env LLAMA_MODEL=${LLAMA_MODEL} \
    --env LLAMA_PORT=${LLAMA_PORT} \
    --env LLAMA_CTX=${LLAMA_CTX} \
    --env LLAMA_NGL=${LLAMA_NGL} \
    --env LLAMA_PARALLEL=${LLAMA_PARALLEL} \
    ${SPLIT_ARGS} \
    ${LLAMA_SIF} \
    sh /opt/scripts/llama-serve.sh