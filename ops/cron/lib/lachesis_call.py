#!/usr/bin/env python3
"""Call one Lachesis MCP tool from shell, with the factory token (lib/lachesis.sh).

    python3 -B lachesis_call.py <tool> [json-arguments]

Prints the tool's text result (JSON for every Lachesis tool) on stdout. Exit 0 when
the tool answered, 1 when it refused (its text on stderr), 2 when Lachesis could not
be reached or LACHESIS_FACTORY_TOKEN is unset. Stdlib only; the MCP client is
lachesis_report.py's.

Env: LACHESIS_URL (default https://lachesis.interstellarai.net/mcp),
     LACHESIS_FACTORY_TOKEN (secrets.env).
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lachesis_report import DEFAULT_URL, Lachesis  # noqa: E402


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: lachesis_call.py <tool> [json-arguments]", file=sys.stderr)
        return 2
    tool = argv[0]
    try:
        arguments = json.loads(argv[1]) if len(argv) > 1 and argv[1] else {}
    except ValueError as exc:
        print(f"lachesis_call: arguments are not JSON: {exc}", file=sys.stderr)
        return 2
    token = os.environ.get("LACHESIS_FACTORY_TOKEN", "")
    if not token:
        print("lachesis_call: LACHESIS_FACTORY_TOKEN is not set", file=sys.stderr)
        return 2
    client = Lachesis(os.environ.get("LACHESIS_URL") or DEFAULT_URL, token)
    try:
        client.connect()
        ok, text = client.call(tool, arguments)
    except (urllib.error.URLError, RuntimeError, ValueError, OSError) as exc:
        print(f"lachesis_call: {tool} failed: {exc}", file=sys.stderr)
        return 2
    if not ok:
        print(text, file=sys.stderr)
        return 1
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
