#!/bin/sh
#
# Runs INSIDE the llama.cpp Apptainer container (baked into the image at
# /opt/llama.cpp/bin/llama-serve.sh; a bind-mounted copy also works).
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
# Two modes:
#
#   PROFILE mode (default). Passes --profile qwen38-27b-q8-2x3090 to the
#   VeroFess fork. The profile OWNS context size, parallel slots, GPU offload,
#   KV cache type and tensor split, and refuses to start if any of them is set
#   to another value. In this mode LLAMA_CTX, LLAMA_NGL, LLAMA_PARALLEL and
#   TENSOR_SPLIT must be left UNSET; the script stops with a clear error
#   instead of letting llama-server fail on a less obvious one.
#
#   GENERIC mode (LLAMA_PROFILE= , i.e. set to empty). Plain llama.cpp
#   behaviour for any other model; the knobs below are passed through.
#
# Expected environment (pass with apptainer --env, or export before launch):
#   LLAMA_MODEL       path to the .gguf INSIDE the container (required)
#   LLAMA_PROFILE     deployment profile          (default qwen38-27b-q8-2x3090;
#                                                  set empty for generic mode)
#   LLAMA_PORT        private loopback port       (default 8080)
#   LLAMA_ALIAS       model name in the API       (default local-model)
#   SPLIT_MODE        layer | tensor              (default tensor in profile
#                                                  mode, layer in generic mode)
#   LLAMA_UBATCH      physical batch size         (profile mode, default 1024)
#   LLAMA_REASONING   on | off | auto             (profile mode, default off)
#   LLAMA_CTX         context size                (generic mode, default 16384)
#   LLAMA_NGL         GPU layers                  (generic mode, default 999)
#   LLAMA_PARALLEL    parallel slots              (generic mode, default 4)
#   TENSOR_SPLIT      e.g. 1,1                    (generic mode, default 1,1)
#   LLAMA_EXTRA_ARGS  extra llama-server flags, whitespace-separated
#   LLAMA_BIN         server binary               (default llama-server)
#   LLM_SOCKET        socket path in container    (default /run/llm/llm.sock)
#   LLAMA_STOP_TIMEOUT seconds to wait for llama-server to release the GPUs
#                     on shutdown before SIGKILL  (default 30)
#   NCCL_SOCKET_IFNAME NCCL bootstrap interface   (default lo; under
#                     --network none it is the only interface there is)

set -eu

: "${LLAMA_MODEL:?LLAMA_MODEL must be set (path inside the container)}"
LLAMA_PROFILE="${LLAMA_PROFILE-qwen38-27b-q8-2x3090}"   # '-' not ':-': empty = generic
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_ALIAS="${LLAMA_ALIAS:-local-model}"
LLAMA_BIN="${LLAMA_BIN:-llama-server}"
LLM_SOCKET="${LLM_SOCKET:-/run/llm/llm.sock}"
LLAMA_EXTRA_ARGS="${LLAMA_EXTRA_ARGS:-}"
LLAMA_STOP_TIMEOUT="${LLAMA_STOP_TIMEOUT:-30}"
export NCCL_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-lo}"

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

# ---- build the llama-server argument list in "$@" ---------------------------
set -- \
    --model "$LLAMA_MODEL" \
    --host 127.0.0.1 \
    --port "$LLAMA_PORT" \
    --alias "$LLAMA_ALIAS"

if [ -n "$LLAMA_PROFILE" ]; then
    for var in LLAMA_CTX LLAMA_NGL LLAMA_PARALLEL TENSOR_SPLIT; do
        eval "val=\${$var:-}"
        if [ -n "$val" ]; then
            echo "error: $var=$val conflicts with --profile $LLAMA_PROFILE, which sets it" \
                 "itself. Unset $var, or set LLAMA_PROFILE= (empty) for generic mode." >&2
            exit 1
        fi
    done
    SPLIT_MODE="${SPLIT_MODE:-tensor}"
    set -- "$@" \
        --profile "$LLAMA_PROFILE" \
        --split-mode "$SPLIT_MODE" \
        --ubatch-size "${LLAMA_UBATCH:-1024}" \
        --reasoning "${LLAMA_REASONING:-off}" \
        --reasoning-preserve \
        --metrics
    mode_desc="profile $LLAMA_PROFILE, split-mode $SPLIT_MODE"
else
    SPLIT_MODE="${SPLIT_MODE:-layer}"
    set -- "$@" \
        --ctx-size "${LLAMA_CTX:-16384}" \
        --n-gpu-layers "${LLAMA_NGL:-999}" \
        --parallel "${LLAMA_PARALLEL:-4}" \
        --split-mode "$SPLIT_MODE" \
        --tensor-split "${TENSOR_SPLIT:-1,1}"
    mode_desc="generic, split-mode $SPLIT_MODE"
fi

if [ -n "$LLAMA_EXTRA_ARGS" ]; then
    set -f                              # split on whitespace, but never glob
    # shellcheck disable=SC2086
    set -- "$@" $LLAMA_EXTRA_ARGS
    set +f
fi

# ---- process supervision ------------------------------------------------------
llama_pid=""
socat_pid=""

# True only for a process that exists AND has not exited. `kill -0` alone also
# succeeds on a zombie (exited but not yet reaped), and dash does not reliably
# reap background children until `wait` is called, so a crashed llama-server
# could otherwise look alive forever.
alive() {
    [ -n "$1" ] || return 1
    kill -0 "$1" 2>/dev/null || return 1
    case "$(sed -n 's/^.*) \(.\).*$/\1/p' "/proc/$1/stat" 2>/dev/null)" in
        Z|X) return 1 ;;
    esac
    return 0
}

terminate() {
    trap - TERM INT EXIT
    [ -n "$socat_pid" ] && kill "$socat_pid" 2>/dev/null || true
    [ -n "$llama_pid" ] && kill "$llama_pid" 2>/dev/null || true
    # Give llama-server time to free GPU memory and NCCL state before the
    # container goes away; a half-dead server holding both GPUs blocks the
    # restart that process-compose is about to attempt.
    i=0
    while alive "$llama_pid" && [ "$i" -lt "$LLAMA_STOP_TIMEOUT" ]; do
        sleep 1
        i=$((i + 1))
    done
    if alive "$llama_pid"; then
        echo "llama-server did not stop within ${LLAMA_STOP_TIMEOUT}s; killing it" >&2
        kill -9 "$llama_pid" 2>/dev/null || true
    fi
    wait 2>/dev/null || true
}
trap 'terminate; exit 143' TERM
trap 'terminate; exit 130' INT
trap 'terminate' EXIT

echo "starting $LLAMA_BIN on 127.0.0.1:$LLAMA_PORT (private loopback; $mode_desc)"
"$LLAMA_BIN" "$@" &
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
while alive "$llama_pid" && alive "$socat_pid"; do
    sleep 1
done

if ! alive "$llama_pid"; then
    # Exit codes 70 (watchdog timeout) and 71 (unrecoverable CUDA error) are
    # the fork's signal that a clean CUDA context is needed: restart is right.
    wait "$llama_pid" 2>/dev/null && rc=0 || rc=$?
    echo "llama-server exited (status $rc); shutting down the bridge" >&2
else
    echo "socat bridge exited; shutting down llama-server" >&2
fi

exit 1
