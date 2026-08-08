#!/usr/bin/env python3

import tempfile
from pathlib import Path

import bootstrap
from bootstrap import load_secrets


def test_secret_loading() -> None:
    with tempfile.TemporaryDirectory() as directory:
        secrets = Path(directory)
        (secrets / "anthropic-api.key").write_text("key\n", encoding="utf-8")
        (secrets / "nested").mkdir()
        environment: dict[str, str] = {"ANTHROPIC_API_KEY": "old"}

        load_secrets(secrets, environment)

        assert environment["ANTHROPIC_API_KEY"] == "key"


def test_collisions_fail() -> None:
    with tempfile.TemporaryDirectory() as directory:
        secrets = Path(directory)
        (secrets / "foo-bar").write_text("one", encoding="utf-8")
        (secrets / "foo.bar").write_text("two", encoding="utf-8")

        try:
            load_secrets(secrets, {})
        except RuntimeError as error:
            assert "FOO_BAR" in str(error)
        else:
            raise AssertionError("expected normalized secret name collision")


class UnreadableEntry:
    name = "secret"

    def is_file(self) -> bool:
        return True

    def read_text(self, **_: object) -> str:
        raise PermissionError("permission denied")


class UnreadableDirectory:
    def is_dir(self) -> bool:
        return True

    def iterdir(self) -> list[UnreadableEntry]:
        return [UnreadableEntry()]


def test_unreadable_files_fail() -> None:
    try:
        load_secrets(UnreadableDirectory(), {})  # type: ignore[arg-type]
    except PermissionError:
        pass
    else:
        raise AssertionError("expected unreadable secret to fail")


def test_invalid_utf8_fails() -> None:
    with tempfile.TemporaryDirectory() as directory:
        secret = Path(directory) / "secret"
        secret.write_bytes(b"\xff")

        try:
            load_secrets(secret.parent, {})
        except UnicodeDecodeError:
            pass
        else:
            raise AssertionError("expected invalid UTF-8 secret to fail")


class RunningProcess:
    def poll(self) -> None:
        return None


class ExitedProcess:
    def poll(self) -> int:
        return 1


class FakePopen:
    def __init__(self, events: list[str], process: object) -> None:
        self.events = events
        self.process = process

    def __call__(self, command: list[str], **_: object) -> object:
        self.events.append("xvfb:" + " ".join(command))
        return self.process


def test_lifecycle_order_and_arguments() -> None:
    events: list[str] = []
    original_loader = bootstrap.load_secrets
    bootstrap.load_secrets = lambda: events.append("secrets")
    try:
        bootstrap.run(
            ["--model", "test"],
            popen=FakePopen(events, RunningProcess()),
            execvp=lambda program, command: events.append(f"exec:{program}:{command}"),
        )
    finally:
        bootstrap.load_secrets = original_loader

    assert events == [
        "secrets",
        "xvfb:Xvfb :99 -screen 0 1024x768x24",
        "exec:opencode:['opencode', '--model', 'test']",
    ]


def test_exited_xvfb_fails() -> None:
    try:
        bootstrap.start_xvfb(FakePopen([], ExitedProcess()))
    except RuntimeError as error:
        assert "exited" in str(error)
    else:
        raise AssertionError("expected exited Xvfb to fail")


def test_missing_xvfb_fails() -> None:
    def missing_xvfb(*_: object, **__: object) -> object:
        raise FileNotFoundError("Xvfb")

    try:
        bootstrap.start_xvfb(missing_xvfb)
    except RuntimeError as error:
        assert "Xvfb" in str(error)
    else:
        raise AssertionError("expected missing Xvfb to fail")


if __name__ == "__main__":
    test_secret_loading()
    test_collisions_fail()
    test_unreadable_files_fail()
    test_invalid_utf8_fails()
    test_lifecycle_order_and_arguments()
    test_exited_xvfb_fails()
    test_missing_xvfb_fails()
    print("bootstrap checks passed")
