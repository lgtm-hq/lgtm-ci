#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Hostile caller checkout for release updater isolation tests
#
# The version-PR job holds the caller's release App token and runs the
# ecosystem updaters with the caller's checkout as the working directory
# (#1356, #1545). These helpers lay out a caller checkout whose files run
# code when a tool picks them up, so tests can prove the updaters never do.
# Every hostile file appends a line to $HOSTILE_IMPORT_MARKER when it runs.
#
# Usage: In your .bats file:
#   load "../../../helpers/hostile_caller"

HOSTILE_CALLER="${PROJECT_ROOT}/tests/fixtures/release/hostile-caller"

# Copy fixture <name>.fixture from the hostile caller into the current
# directory as <dest> (default: <name>).
# Usage: hostile_caller_copy <name> [dest]
hostile_caller_copy() {
	local name="$1" dest="${2:-$1}"
	mkdir -p "$(dirname "$dest")"
	cp "${HOSTILE_CALLER}/${name}.fixture" "$dest"
}

# Copy the hostile caller checkout into the current directory under its real
# names (tomlkit.py, pip.py, pyproject.toml). The committed copies carry a
# .fixture suffix so they never shadow pip or tomlkit for tools run in the
# repo: lintro runs pip-audit (`python -m pip`) in every directory with a
# pyproject.toml. Then put a python3 shim at ${BATS_TEST_TMPDIR}/shim for
# callers to place first on PATH. The shim forwards every call to the real
# python3 from the same working directory, so caller modules resolve exactly
# as they would. It makes `-c 'import tomlkit'` report "missing" after the
# real import ran, and turns `-m pip install` into a network-free
# `-m pip --version`, so both lookups happen without installing anything.
hostile_caller_setup() {
	local name
	for name in tomlkit.py pip.py pyproject.toml; do
		hostile_caller_copy "$name"
	done
	export HOSTILE_IMPORT_MARKER="${BATS_TEST_TMPDIR}/hostile-imported"
	REAL_PYTHON3="$(command -v python3)"
	export REAL_PYTHON3
	mkdir -p "${BATS_TEST_TMPDIR}/shim"
	cat >"${BATS_TEST_TMPDIR}/shim/python3" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" && "${2:-}" == "import tomlkit" ]]; then
	"$REAL_PYTHON3" "$@" >/dev/null 2>&1
	exit 1
fi
if [[ "${1:-}" == "-m" && "${2:-}" == "pip" ]]; then
	"$REAL_PYTHON3" -m pip --version >/dev/null 2>&1
	exit 0
fi
exec "$REAL_PYTHON3" "$@"
EOF
	chmod +x "${BATS_TEST_TMPDIR}/shim/python3"
}

# True when the real tomlkit is importable (checked from / so a hostile copy
# in the current directory does not answer).
hostile_caller_real_tomlkit() {
	(cd / && "${REAL_PYTHON3:-python3}" -c 'import tomlkit' 2>/dev/null)
}
