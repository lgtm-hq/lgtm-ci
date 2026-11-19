# Playwright browser install fixtures (#1433)

Test data for `scripts/ci/lib/playwright_browsers.py`, `playwright_dry_run.py` and
`playwright_ldd.py`, used by `tests/python/test_playwright_browsers.py` and the BATS suites
of `run-playwright.sh` and `run-playwright-tests.sh`.

## `install-dry-run-<version>-<case>.txt`

Real stdout of `playwright install --dry-run`, captured on 2026-11-19 by running the
published `playwright-core` package of each version (its `cli.js`, Node 26, macOS arm64) with
`PLAYWRIGHT_BROWSERS_PATH=/ROOTPH`. The dry run downloads nothing. Two edits only: the
placeholder root is written as `@ROOT@`, which the tests replace with a temporary directory,
and the trailing blank line is dropped. Download URLs and host revisions are the macOS arm64
ones; the record format does not depend on the host.

| Version | Header format                                   | Used by        |
| ------- | ----------------------------------------------- | -------------- |
| 1.56.1  | `browser: <name>[ version <v>]`                 | 1.57 and older |
| 1.60.0  | `<Title>[ <v>] (playwright <name> v<revision>)` | 1.58 and newer |
| 1.61.0  | same as 1.60.0                                  | 1.58 and newer |
| 1.63.0  | same as 1.60.0                                  | 1.58 and newer |

| Case                  | Command                                     |
| --------------------- | ------------------------------------------- |
| `chromium`            | `install --dry-run chromium`                |
| `only-shell-chromium` | `install --dry-run --only-shell chromium`   |
| `webkit`              | `install --dry-run webkit`                  |
| `chrome-channel`      | `install --dry-run chrome` (`<system>`)     |

The 1.56.1 `chromium` output lists FFmpeg twice, as Playwright prints it.

## Others

- `ldd-resolved.txt`, `ldd-missing.txt`, `ldd-static.txt`: `ldd` output with every library
  found, with two missing, and for a static file.
- `os-release-ubuntu-24.04`: an Ubuntu 24.04 `/etc/os-release`.
