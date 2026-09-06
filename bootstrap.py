#!/usr/bin/env python3

import os
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable
from pathlib import Path


SECRETS_DIR = Path("/run/secrets")

# When the launcher runs with --no-net, the container has a private, empty
# network namespace. The only path out is a Unix socket bound in from the host,
# relayed onto the container's own loopback so that an unmodified
# `baseURL: http://127.0.0.1:<port>/v1` keeps working.
LLM_SOCKET = Path(os.environ.get("OPENCODE_LLM_SOCKET", "/run/llm/llm.sock"))
LLM_PORT = os.environ.get("OPENCODE_LLM_PORT", "11434")

def env_var_name(secret_name: str) -> str:
    return secret_name.upper().replace("-", "_").replace(".", "_")


def load_secrets(secrets_dir: Path = SECRETS_DIR, environ: dict[str, str] | None = None) -> None:
    if not secrets_dir.is_dir():
        return

    environ = os.environ if environ is None else environ
    seen: dict[str, str] = {}  # normalized env var -> original filename
    for entry in secrets_dir.iterdir():
        if not entry.is_file():
            continue

        name = env_var_name(entry.name)
        if name in seen:
            raise RuntimeError(f"secret name collision: {seen[name]} and {entry.name} -> {name}")

        seen[name] = entry.name
        value = entry.read_text(encoding="utf-8").rstrip("\r\n")
        environ[name] = value

def _spawn_checked(
    argv: list[str],
    description: str,
    popen,
    sleep: Callable[[float], None],
    settle: float = 2.0,
):
    """Start a background process and fail loudly if it exits during startup."""
    with tempfile.TemporaryFile() as stderr:
        try:
            process = popen(argv, stdout=subprocess.DEVNULL, stderr=stderr)
        except OSError as error:
            raise RuntimeError(f"failed to start {description}") from error

        deadline = time.monotonic() + settle
        exit_code: int | None = None
        while exit_code is None and time.monotonic() < deadline:
            exit_code = process.poll()
            if exit_code is None:
                sleep(0.05)

        if exit_code is not None:
            stderr.seek(0)
            detail = stderr.read().decode("utf-8", "replace").strip()
            raise RuntimeError(
                f"{description} exited (code {exit_code}) before OpenCode started: {detail}"
            )

        return process

def start_xvfb(popen=subprocess.Popen, sleep: Callable[[float], None] = time.sleep) -> None:
    with tempfile.TemporaryFile() as stderr:
        try:
            process = popen(
                ["Xvfb", ":99", "-screen", "0", "1024x768x24"],
                stdout=subprocess.DEVNULL,
                stderr=stderr,
            )
        except OSError as error:
            raise RuntimeError("failed to start Xvfb on display :99") from error

        deadline = time.monotonic() + 2.0
        exit_code: int | None = None
        while exit_code is None and time.monotonic() < deadline:
            exit_code = process.poll()
            if exit_code is None:
                sleep(0.05)

        if exit_code is not None:
            stderr.seek(0)
            detail = stderr.read().decode("utf-8", "replace").strip()
            raise RuntimeError(
                f"Xvfb exited (code {exit_code}) before OpenCode started: {detail}"
            )

def start_llm_relay(
    socket_path: Path = LLM_SOCKET,
    port: str = LLM_PORT,
    popen=subprocess.Popen,
    sleep: Callable[[float], None] = time.sleep,
):
    """Relay container loopback -> bound Unix socket.

    No socket bound means the launcher was run without --no-net, so the host
    network is shared and no relay is needed. Absence is not an error.
    """
    if not socket_path.exists():
        return None

    if not socket_path.is_socket():
        raise RuntimeError(f"{socket_path} exists but is not a socket")

    return _spawn_checked(
        [
            "socat",
            f"TCP-LISTEN:{port},bind=127.0.0.1,fork,reuseaddr",
            f"UNIX-CONNECT:{socket_path}",
        ],
        f"socat relay 127.0.0.1:{port} -> {socket_path}",
        popen,
        sleep,
    )


def bootstrap(args: list[str], popen=subprocess.Popen, execvp=os.execvp) -> None:
    load_secrets()
    start_xvfb(popen)
    start_llm_relay(popen=popen)
    execvp("opencode", ["opencode", *args])


def main() -> None:
    bootstrap(sys.argv[1:])


if __name__ == "__main__":
    main()
