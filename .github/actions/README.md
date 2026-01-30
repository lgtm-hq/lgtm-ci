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

## Security Actions

### harden-runner

Security hardening using [StepSecurity](https://stepsecurity.io).

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/harden-runner@main
  with:
    egress-policy: 'audit'        # or 'block' to enforce allowlist
    disable-sudo: 'false'         # optional
```

**Features:**
- Network egress monitoring and blocking
- Optional sudo disabling
- Integrates with StepSecurity dashboard

---

### secure-checkout

Security-hardened repository checkout with sensible defaults.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/secure-checkout@main
  with:
    persist-credentials: 'false'  # default: false (secure)
    fetch-depth: '1'              # default: 1 (shallow clone)
```

**Security defaults:**
- `persist-credentials: false` - Credentials not stored in git config
- Checkout integrity verification
- All standard checkout options supported

**Outputs:**
- `ref` - The resolved ref that was checked out
- `commit` - The commit SHA that was checked out

---

### egress-audit

Network egress configuration and reporting scaffolding.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/egress-audit@main
  with:
    mode: 'audit'                 # 'audit', 'report', or 'block'
    report-format: 'summary'      # 'summary', 'json', or 'none'
```

**Features:**
- Pre-configured allowlist for common package registries
- GitHub Step Summary report generation
- Works alongside harden-runner for enforcement

**Default allowed domains:**
- GitHub (`github.com`, `api.github.com`, `ghcr.io`, etc.)
- npm (`registry.npmjs.org`)
- PyPI (`pypi.org`, `files.pythonhosted.org`)
- Crates.io (`crates.io`, `static.crates.io`)
- RubyGems (`rubygems.org`)

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
      # Security hardening (should be first)
      - uses: lgtm-hq/lgtm-ci/.github/actions/harden-runner@main
        with:
          egress-policy: audit

      # Secure checkout (replaces actions/checkout)
      - uses: lgtm-hq/lgtm-ci/.github/actions/secure-checkout@main

      # Environment setup
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
