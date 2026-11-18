# SPDX-License-Identifier: MIT
"""The program extraction behind the tool-coverage test (#1624).

``tests/python/test_inline_shell_tools.py`` holds what
``inline_shell_tools`` finds to the deny list; these tests pin what the
extraction reads as a program, through wrappers too.
"""

from __future__ import annotations

from pathlib import Path

import inline_shell_tools
from assertpy import assert_that


def test_shell_extraction_reads_commands_only(tmp_path: Path) -> None:
    """Quoted text, heredocs, comments, tests and arrays are not commands."""
    script = (
        "#!/usr/bin/env bash\n"
        "# comment: notacmd1\n"
        "x=$(alpha --y) && beta | gamma\n"
        'echo "text; notacmd2 $(delta)"\n'
        "awk '{ print }\nnotacmd3 x' f\n"
        "cat <<'EOF'\nnotacmd4\nEOF\n"
        'if [[ "$v" =~ (notacmd5|x) ]]; then epsilon; fi\n'
        "arr=(notacmd6 b)\n"
        "(( n++ ))\n"
        ': "${V:="{}"}"\n'
        'case "$k" in\n  notacmd7 | b) zeta ;;\nesac\n'
        "myfunc() { eta; }\n"
        "myfunc\n"
        "sudo -E theta\n"
        "timeout -k 5 30 lambdaa\n"
        "timeout --kill-after 5 30 muu\n"
        "sudo -u root nuu\n"
        "LC_ALL=C iota \\\n  --flag\n"
        "read -r v <<<word\n"
        "kappa\n"
        "word\n"
    )
    (tmp_path / "s.sh").write_text(script, encoding="utf-8")
    found = set(inline_shell_tools.programs(tmp_path))
    expected = {"alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"}
    # A prefix option that takes a value skips the value too (timeout -k 5).
    expected |= {"lambdaa", "muu", "nuu"}
    extra = {"iota", "kappa", "word", "cat", "awk"}
    assert_that(found).is_equal_to(expected | extra)


def test_python_extraction_reads_argv_literals(tmp_path: Path) -> None:
    """A subprocess call, a command-line variable and ``shutil.which`` are read."""
    (tmp_path / "p.py").write_text(
        "import shutil, subprocess\n"
        'subprocess.run(["/usr/bin/alpha", "x"])\n'
        'args = ["beta", "y"]\n'
        'commands = [["gamma"], ["delta", "z"]]\n'
        'shutil.which("epsilon")\n'
        'print(["notaprogram", "x"])\n',
        encoding="utf-8",
    )
    found = set(inline_shell_tools.programs(tmp_path))
    assert_that(found).is_equal_to({"alpha", "beta", "gamma", "delta", "epsilon"})


def test_shell_extraction_reads_wrapped_programs(tmp_path: Path) -> None:
    """A wrapper counts with the program it runs, past the wrapper's options."""
    script = (
        "#!/usr/bin/env bash\n"
        "pm_exec() { :; }\n"
        "pm_exec_argv() { :; }\n"
        "run_python() { :; }\n"
        "uv run --frozen --with twine --no-sync --project x alpha --y\n"
        "uvx --from pkg beta\n"
        "npx --no-install --yes -y gamma\n"
        "bunx delta\n"
        "bun x --no-install epsilon\n"
        "pnpm exec zeta\n"
        "pnpm dlx eta\n"
        "npm exec -- theta\n"
        "pm_exec iota --flag\n"
        "pm_exec_argv kappa || exit 1\n"
        "python -m lambda_ x\n"
        "python3 -I -m mu\n"
        "python3 -Im nu\n"
        "run_python -W ignore -m xi\n"
        'python3 -c "import notamodule"\n'
        "uv run --frozen python -m omicron\n"
    )
    (tmp_path / "w.sh").write_text(script, encoding="utf-8")
    found = set(inline_shell_tools.programs(tmp_path))
    wrapped = {"alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"}
    modules = {"iota", "kappa", "lambda_", "mu", "nu", "xi", "omicron"}
    wrappers = {"uv", "uvx", "npx", "bunx", "bun", "pnpm", "npm", "python", "python3"}
    assert_that(found).is_equal_to(wrapped | modules | wrappers)


def test_python_extraction_reads_wrapped_programs(tmp_path: Path) -> None:
    """An argv literal that starts with a wrapper counts the wrapped program."""
    (tmp_path / "p.py").write_text(
        "import subprocess\n"
        'subprocess.run(["uv", "run", "--frozen", "alpha"])\n'
        'cmd = ["python3", "-I", "-m", "beta", "x"]\n'
        'argv = ["npx", "--no-install", "gamma"]\n',
        encoding="utf-8",
    )
    found = set(inline_shell_tools.programs(tmp_path))
    assert_that(found).is_equal_to({"uv", "alpha", "python3", "beta", "npx", "gamma"})
