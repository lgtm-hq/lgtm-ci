# SPDX-License-Identifier: MIT
"""Hostile caller module: records that caller code was imported (#1356).

A caller repository can commit a ``tomlkit.py``. Release tooling that runs
``python3 -c 'import tomlkit'`` from the caller checkout would import this
instead of the real package, inside a job that holds the App token.
"""

import os
from pathlib import Path

_MARKER = os.environ.get("HOSTILE_IMPORT_MARKER", "")
if _MARKER:
    with Path(_MARKER).open("a", encoding="utf-8") as marker:
        marker.write("tomlkit\n")
