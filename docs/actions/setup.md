# Setup actions

Environment setup composites. Each installs a toolchain and enables caching;
combine with [security actions](security.md) (`secure-checkout`,
`harden-runner`) in a real workflow — see
[Usage example](README.md#usage-example).

## setup-env

Configure common CI environment variables and PATH.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-env@main
  with:
    bin-dir: "${{ github.workspace }}/.local/bin" # optional
    add-to-path: "/custom/path1, /custom/path2" # optional
```

**Outputs:** `platform`, `os`, `arch`, `bin-dir`.

**Environment variables set:** `CI=true`, `NONINTERACTIVE=1`,
`DO_NOT_TRACK=1`, and telemetry opt-outs for common tools.

## setup-python

Setup Python with [uv](https://github.com/astral-sh/uv).

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-python@main
  with:
    python-version: "3.12" # optional, default: 3.12
    uv-version: "latest" # optional
    cache: "true" # optional, default: true
    install-dependencies: "true" # optional, default: true
```

**Outputs:** `python-version`, `uv-version`, `cache-hit`.

Auto-installs dependencies from `pyproject.toml`, `uv.lock`, or
`requirements.txt`; caches uv dependencies and virtual environments. Uses
[astral-sh/setup-uv](https://github.com/astral-sh/setup-uv) under the hood.

## setup-node

Setup Node.js with [bun](https://bun.sh).

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-node@main
  with:
    node-version: "22" # optional, default: 22
    bun-version: "latest" # optional
    cache: "true" # optional, default: true
    install-dependencies: "true" # optional, default: true
    frozen-lockfile: "true" # optional, default: true
```

**Outputs:** `node-version`, `bun-version`, `cache-hit`.

`bun install --frozen-lockfile` by default for reproducible CI builds; caches
the bun cache directory and `node_modules`.

## setup-rust

Setup Rust toolchain with cargo caching.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-rust@main
  with:
    toolchain: "stable" # optional, default: stable
    components: "clippy, rustfmt" # optional
    targets: "wasm32-unknown-unknown" # optional
    cache: "true" # optional, default: true
```

**Outputs:** `rustc-version`, `cargo-version`, `cache-hit`.

Installs cargo-binstall for faster binary installs, enables the sparse
registry protocol, and caches the cargo registry, git deps, and target
directory. Uses
[dtolnay/rust-toolchain](https://github.com/dtolnay/rust-toolchain).

## setup-ruby

Setup Ruby with Bundler and gem caching.

```yaml
- uses: lgtm-hq/lgtm-ci/.github/actions/setup-ruby@main
  with:
    ruby-version: "3.3" # optional, default: 3.3
    bundler-version: "latest" # optional
    cache: "true" # optional, default: true
    cache-dependency-path: "**/Gemfile.lock" # optional
    working-directory: "." # optional
    install-dependencies: "true" # optional, default: true
```

**Outputs:** `ruby-version`, `bundler-version`.

Runs `bundle install` in `working-directory` when `install-dependencies` is
true; caches gems keyed on `cache-dependency-path`.
