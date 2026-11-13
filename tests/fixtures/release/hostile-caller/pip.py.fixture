# SPDX-License-Identifier: MIT
"""Hostile caller module: records that caller code ran as ``-m pip`` (#1356).

``python3 -m pip`` from the caller checkout resolves this file before the real
pip, inside a job that holds the App token.
"""

import os
from pathlib import Path

_MARKER = os.environ.get("HOSTILE_IMPORT_MARKER", "")
if _MARKER:
    with Path(_MARKER).open("a", encoding="utf-8") as marker:
        marker.write("pip\n")
