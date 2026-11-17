# SPDX-License-Identifier: MIT
"""A scratch ``.github`` tree for the tooling App credential tests (#1622).

Shared by ``tests/python/test_tooling_app_*.py``. The tree holds copies of the
real ``checkout-and-harden`` composite and the real pilot reusable, so every
case starts from the generated blocks that ship.
"""

from __future__ import annotations

import shutil
from pathlib import Path
from types import ModuleType

from assertpy import assert_that

ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = "scripts/ci/quality/validate_tooling_token.py"
PILOT = "reusable-semantic-pr-title.yml"
BOOTSTRAP = ROOT / "scripts" / "ci" / "bootstrap"
MINT_SOURCE = BOOTSTRAP / "tooling-app-mint.yml"
FLAGS_SOURCE = BOOTSTRAP / "tooling-app-flags.yml"
# The pilot's consumer values, as folded in the file.
REQUESTED_LINE = (
    "            ${{ (secrets.LGTM_CI_TOOLING_APP_CLIENT_ID != '' "
    "|| secrets.LGTM_CI_TOOLING_APP_PRIVATE_KEY != '')\n"
    "            && (steps.tooling-app-token.outputs.token || 'no-tooling-app-token')\n"
)
TOKEN_BLOCK = (
    "          token: >-\n"
    + REQUESTED_LINE
    + "            || secrets.LGTM_CI_TOOLING_TOKEN || github.token }}\n"
)
FORWARD_BLOCK = (
    "          tooling-token: >-\n"
    + REQUESTED_LINE
    + "            || secrets.LGTM_CI_TOOLING_TOKEN }}\n"
)


class Tree:
    """Scratch copies of the real composite and pilot, edited per case.

    Args:
        github: The scratch ``.github`` directory.
        validator: The loaded validator module.
    """

    def __init__(self, github: Path, validator: ModuleType) -> None:
        self.validator = validator
        self.github = github
        shutil.copytree(
            ROOT / ".github" / "actions" / "checkout-and-harden",
            github / "actions" / "checkout-and-harden",
        )
        (github / "workflows").mkdir()
        self.pilot = (ROOT / ".github" / "workflows" / PILOT).read_text(
            encoding="utf-8",
        )
        self.write(PILOT, self.pilot)

    def write(self, name: str, text: str) -> None:
        """Write one workflow under ``.github/workflows``."""
        (self.github / "workflows" / name).write_text(text, encoding="utf-8")

    def edit(self, old: str, new: str, count: int = 1) -> None:
        """Rewrite the pilot copy, failing when ``old`` is not in it."""
        assert_that(self.pilot).contains(old)
        self.pilot = self.pilot.replace(old, new, count)
        self.write(PILOT, self.pilot)

    def run(self) -> list[str]:
        """Return the rendered violations of the scratch tree."""
        directories = {
            "workflows_dir": self.github / "workflows",
            "actions_dir": self.github / "actions",
        }
        return [item.render() for item in self.validator.validate(**directories)[0]]

    def findings(self) -> str:
        """Return the rendered violations as one text, for ``contains``."""
        return "\n".join(self.run())
