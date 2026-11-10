#!/bin/sh
''''exec "${PALAVER_E2E_PYTHON:-python3}" "$0" "$@" # sh runs this line; for Python it opens the docstring

The `claude` command palaver-server finds first on its PATH in the end-to-end tests: it
never is the real Claude Code. Each call is one JSON line (its arguments) in
``$PALAVER_E2E_FAKE_CLAUDE``; ``mcp add --scope user <name> -- <command> <args…>``
writes the entry into ``$HOME/.claude.json`` as Claude Code does (HOME is the test's
own home: the server sets it for every claude it runs), ``mcp remove <name>`` drops it.
'''

import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
with open(os.environ["PALAVER_E2E_FAKE_CLAUDE"], "a", encoding="utf-8") as f:
    f.write(json.dumps(args) + "\n")
config_path = Path(os.environ["HOME"]) / ".claude.json"
try:
    config = json.loads(config_path.read_text())
except FileNotFoundError:
    config = {}
servers = config.setdefault("mcpServers", {})
if args[:2] == ["mcp", "add"] and "--" in args:
    i = args.index("--")
    servers[args[i - 1]] = {"type": "stdio", "command": args[i + 1], "args": args[i + 2:], "env": {}}
elif args[:2] == ["mcp", "remove"]:
    servers.pop(args[2], None)
config_path.write_text(json.dumps(config, indent=2) + "\n")
