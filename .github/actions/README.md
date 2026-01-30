# Composite Actions

Reusable GitHub Actions for consistent CI/CD setup across repositories.

## Available Actions

### setup-env

Configure common CI environment variables and PATH.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@main
  with:
    bin-dir: '${{ github.workspace }}/.local/bin'  # optional
    add-to-path: '/custom/path1, /custom/path2'    # optional
```

**Outputs:**
- `platform` - Detected platform (e.g., `linux-x86_64`, `darwin-arm64`)
- `os` - Detected OS (`linux`, `darwin`, `windows`)
- `arch` - Detected architecture (`x86_64`, `arm64`)
- `bin-dir` - The configured binary directory

**Environment variables set:**
- `CI=true`
- `NONINTERACTIVE=1`
- `DO_NOT_TRACK=1`
- Various telemetry opt-outs

---

### setup-python

Setup Python with [uv](https://github.com/astral-sh/uv) package manager.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-python@main
  with:
    python-version: '3.12'        # optional, default: 3.12
    uv-version: 'latest'          # optional
    cache: 'true'                 # optional, default: true
    install-dependencies: 'true'  # optional, default: true
```

**Outputs:**
- `python-version` - Installed Python version
- `uv-version` - Installed uv version
- `cache-hit` - Whether the cache was hit

**Features:**
- Automatic dependency installation from `pyproject.toml`, `uv.lock`, or `requirements.txt`
- Caching of uv dependencies and virtual environments
- Uses [astral-sh/setup-uv](https://github.com/astral-sh/setup-uv) under the hood

---

### setup-node

Setup Node.js with [bun](https://bun.sh) package manager.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-node@main
  with:
    node-version: '22'            # optional, default: 22
    bun-version: 'latest'         # optional
    cache: 'true'                 # optional, default: true
    install-dependencies: 'true'  # optional, default: true
    frozen-lockfile: 'true'       # optional, default: true
```

**Outputs:**
- `node-version` - Installed Node.js version
- `bun-version` - Installed bun version
- `cache-hit` - Whether the cache was hit

**Features:**
- Automatic dependency installation with `bun install`
- `--frozen-lockfile` by default for reproducible CI builds
- Caching of bun cache directory and node_modules

---

### setup-rust

Setup Rust toolchain with cargo caching.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-rust@main
  with:
    toolchain: 'stable'           # optional, default: stable
    components: 'clippy, rustfmt' # optional
    targets: 'wasm32-unknown-unknown'  # optional
    cache: 'true'                 # optional, default: true
```

**Outputs:**
- `rustc-version` - Installed rustc version
- `cargo-version` - Installed cargo version
- `cache-hit` - Whether the cache was hit

**Features:**
- Automatic cargo-binstall installation for faster binary installs
- Sparse registry protocol enabled by default
- Caching of cargo registry, git deps, and target directory
- Uses [dtolnay/rust-toolchain](https://github.com/dtolnay/rust-toolchain) under the hood

---

## Usage Example

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@main

      - uses: lgtm-hq/lgtm-ci/.github/actions/setup-python@main
        with:
          python-version: '3.12'

      - name: Run tests
        run: uv run pytest
```

## Pinning Versions

For production workflows, pin to a specific commit SHA:

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-python@abc1234
```

Or use a release tag when available:

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-python@v1
```
