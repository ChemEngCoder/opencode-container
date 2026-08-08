#!/usr/bin/env python3

import os
import subprocess
import sys
from pathlib import Path


SECRETS_DIR = Path("/run/secrets")


def env_var_name(secret_name: str) -> str:
    return secret_name.upper().replace("-", "_").replace(".", "_")


def load_secrets(secrets_dir: Path = SECRETS_DIR, environ: dict[str, str] | None = None) -> None:
    if not secrets_dir.is_dir():
        return

    environ = os.environ if environ is None else environ
    names: dict[str, str] = {}
    for entry in secrets_dir.iterdir():
        if not entry.is_file():
            continue

        name = env_var_name(entry.name)
        if name in names:
            raise RuntimeError(f"secret name collision: {names[name]} and {entry.name} -> {name}")

        names[name] = entry.name
        value = entry.read_text(encoding="utf-8").rstrip("\r\n")
        environ[name] = value


def start_xvfb() -> None:
    try:
        subprocess.Popen(
            ["Xvfb", ":99", "-screen", "0", "1024x768x24"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass


def main() -> None:
    load_secrets()
    start_xvfb()
    os.execvp("opencode", ["opencode", *sys.argv[1:]])


if __name__ == "__main__":
    main()
