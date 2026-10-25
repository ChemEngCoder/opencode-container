#!/usr/bin/env python3
"""Measure prompt and generation speed through the llama.cpp Unix socket.

Usage:
    python3 prompt-test.py                       # ~8K-token prompt, default socket
    python3 prompt-test.py --repeat 1600         # ~16K-token prompt
    python3 prompt-test.py --socket /path/to/llm.sock --model local-model

A random prefix makes every run a fresh prompt, so the server cannot reuse a
cached copy. Run it twice and trust the second result (the first may include
warm-up).
"""
import argparse
import http.client
import json
import os
import random
import socket
import sys
import time


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout=900):
        super().__init__("localhost", timeout=timeout)
        self.unix_path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.unix_path)


def main():
    default_sock = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid()), "opencode", "llm.sock")
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", default=default_sock)
    ap.add_argument("--model", default="local-model")
    ap.add_argument("--repeat", type=int, default=800, help="filler sentences (~10 tokens each)")
    ap.add_argument("--max-tokens", type=int, default=64)
    args = ap.parse_args()

    if not os.path.exists(args.socket):
        sys.exit(f"socket not found: {args.socket}  (use --socket)")

    content = f"{random.random()} Summarize in one sentence: " + "The quick brown fox jumps over the lazy dog. " * args.repeat
    body = json.dumps({
        "model": args.model,
        "max_tokens": args.max_tokens,
        "messages": [{"role": "user", "content": content}],
    })

    conn = UnixHTTPConnection(args.socket)
    start = time.time()
    conn.request("POST", "/v1/chat/completions", body, {"Content-Type": "application/json"})
    resp = conn.getresponse()
    raw = resp.read().decode("utf-8", "replace")
    wall = time.time() - start

    if resp.status != 200:
        sys.exit(f"HTTP {resp.status}: {raw[:500]}")
    t = json.loads(raw).get("timings", {})
    print(f"prompt tokens:      {t.get('prompt_n')}  (reused from cache: {t.get('cache_n')})")
    print(f"prompt tok/s:       {t.get('prompt_per_second', 0):.0f}")
    print(f"generated tokens:   {t.get('predicted_n')}")
    print(f"generation tok/s:   {t.get('predicted_per_second', 0):.1f}")
    if t.get("draft_n"):
        print(f"MTP acceptance:     {t['draft_n_accepted']}/{t['draft_n']}")
    print(f"total request time: {wall:.1f} s")


if __name__ == "__main__":
    main()
