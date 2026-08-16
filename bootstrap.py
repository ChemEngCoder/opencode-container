#!/usr/bin/env python3

import os
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable
from pathlib import Path


SECRETS_DIR = Path("/run/secrets")


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


def bootstrap(args: list[str], popen=subprocess.Popen, execvp=os.execvp) -> None:
    load_secrets()
    start_xvfb(popen)
    execvp("opencode", ["opencode", *args])


def main() -> None:
    bootstrap(sys.argv[1:])


if __name__ == "__main__":
    main()
