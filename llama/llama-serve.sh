#!/bin/sh
#
# Runs INSIDE the llama.cpp Apptainer container.
#
# Starts two processes and ties their lifetimes together:
#   1. llama-server, bound to the container's own loopback
#   2. socat, exposing it on a Unix socket bound in from the host
#
# With the container launched under `--net --network none`, that loopback is
# private: llama-server is unreachable from the host and from other users, and
# the Unix socket is the only path in.
#
# Kept as a file rather than an inline `sh -c` in process-compose.yaml because
# $! and $? would otherwise need escaping against process-compose's own
# variable expansion -- a reliable source of silent breakage.
#
# Expected environment (pass with apptainer --env, or export before launch):
#   LLAMA_MODEL   path to the .gguf INSIDE the container (e.g. /models/foo.gguf)
#   LLAMA_PORT    private loopback port                  (default 8080)
#   LLAMA_CTX     context size                           (default 16384)
#   LLAMA_NGL     GPU layers                             (default 999)
#   LLAMA_BIN     server binary                          (default llama-server)
#   LLM_SOCKET    socket path inside the container       (default /run/llm/llm.sock)

set -eu

: "${LLAMA_MODEL:?LLAMA_MODEL must be set (path inside the container)}"
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_CTX="${LLAMA_CTX:-16384}"
LLAMA_NGL="${LLAMA_NGL:-999}"
LLAMA_BIN="${LLAMA_BIN:-llama-server}"
LLM_SOCKET="${LLM_SOCKET:-/run/llm/llm.sock}"

if [ ! -f "$LLAMA_MODEL" ]; then
    echo "error: model not found at $LLAMA_MODEL (check the --bind for MODEL_DIR)" >&2
    exit 1
fi

socket_dir="$(dirname "$LLM_SOCKET")"
if [ ! -d "$socket_dir" ]; then
    echo "error: $socket_dir is not present; bind the host socket dir there" >&2
    exit 1
fi
if [ ! -w "$socket_dir" ]; then
    echo "error: $socket_dir is not writable; bind it :rw, not :ro" >&2
    exit 1
fi

llama_pid=""
socat_pid=""

terminate() {
    [ -n "$llama_pid" ] && kill "$llama_pid" 2>/dev/null || true
    [ -n "$socat_pid" ] && kill "$socat_pid" 2>/dev/null || true
}
trap terminate TERM INT EXIT

echo "starting $LLAMA_BIN on 127.0.0.1:$LLAMA_PORT (private loopback)"
"$LLAMA_BIN" \
    --model "$LLAMA_MODEL" \
    --host 127.0.0.1 \
    --port "$LLAMA_PORT" \
    --ctx-size "$LLAMA_CTX" \
    --n-gpu-layers "$LLAMA_NGL" \
    --alias local-model &
llama_pid=$!

# mode=0600: only the owning UID can connect. unlink-early clears a stale
# socket left behind by an unclean shutdown.
echo "bridging $LLM_SOCKET -> 127.0.0.1:$LLAMA_PORT"
socat \
    UNIX-LISTEN:"$LLM_SOCKET",fork,mode=0600,unlink-early \
    TCP:127.0.0.1:"$LLAMA_PORT" &
socat_pid=$!

# Exit as soon as EITHER dies, so process-compose restarts the pair together.
# A surviving socat with a dead server would accept connections and refuse
# every one of them, which looks like a socket bug from inside OpenCode.
# `wait -n` would be cleaner but is not POSIX sh (dash lacks it).
while kill -0 "$llama_pid" 2>/dev/null && kill -0 "$socat_pid" 2>/dev/null; do
    sleep 1
done

if ! kill -0 "$llama_pid" 2>/dev/null; then
    echo "llama-server exited; shutting down the bridge" >&2
else
    echo "socat bridge exited; shutting down llama-server" >&2
fi

exit 1
