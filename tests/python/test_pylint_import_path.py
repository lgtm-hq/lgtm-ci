# SPDX-License-Identifier: MIT
"""Exercise the native Pylint hook without requiring lint tools in test CI."""

import json
import subprocess
import sys
import tomllib
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize(
    ("container", "matching_minor", "path_exists", "expected"),
    [
        (True, True, True, True),
        (False, True, True, False),
        (True, False, True, False),
        (True, True, False, False),
    ],
)
def test_pylint_application_path(
    tmp_path: Path,
    container: bool,
    matching_minor: bool,
    path_exists: bool,
    expected: bool,
) -> None:
    """Only Docker's existing, same-minor application packages are appended."""
    config = tomllib.loads((PROJECT_ROOT / "pyproject.toml").read_text())
    hook = config["tool"]["pylint"]["main"]["init-hook"]
    app = tmp_path / "app"
    marker = tmp_path / ".dockerenv"
    if container:
        marker.touch()
    version = ".".join(map(str, sys.version_info[:2]))
    if not matching_minor:
        version = "0.0"
    packages = app / ".venv" / "lib" / f"python{version}" / "site-packages"
    if path_exists:
        packages.mkdir(parents=True)
    # Merely adding an analysis path must not process executable .pth files.
    executed = tmp_path / "executed"
    if path_exists:
        (packages / "probe.pth").write_text(
            f"import pathlib; pathlib.Path({str(executed)!r}).touch()\n"
        )
    hook = hook.replace("/app/", f"{app}/").replace("/.dockerenv", str(marker))
    script = (
        "import json, sys\n"
        "before = sys.path.copy()\n"
        f"{hook}\n"
        "print(json.dumps({'before': before, 'after': sys.path}))\n"
    )
    result = subprocess.run(
        [sys.executable, "-c", script],
        check=True,
        capture_output=True,
        text=True,
    )
    paths = json.loads(result.stdout)
    assert paths["after"] == paths["before"] + ([str(packages)] if expected else [])
    assert not executed.exists()
