# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

## [0.6.3] - 2026-02-21

### Bug Fixes

- add Renovate rule for container image digest pinning (#79) (e1d20a3)

## [0.6.2] - 2026-02-20

### Bug Fixes

- **actions**: normalize Windows paths in all composite actions (#77) (f31059e)

## [0.6.1] - 2026-02-20

### Bug Fixes

- **actions**: resolve secure-checkout path failure on Windows runners (#75) (27529c3)

### Documentation

- revamp README to match org standards (#72) (64dc59a)

### Other Changes

- add Renovate workflow (#71) (17e64ec)

## [0.6.0] - 2026-02-11

### Features

- **workflows**: add reusable release-auto-tag workflow (#60) (5d22dcb)

### Bug Fixes

- **release**: deduplicate changelog when same version is re-created (#63) (b7fef51)
- **workflows**: use github.sha as default tooling-ref in auto-tag workflow (#62) (b911193)

### Other Changes

- **release**: version 0.6.0 (#61) (3c6f9e9)

## [0.5.1] - 2026-02-10

### Bug Fixes

- **workflows**: fall back to full CODEOWNERS list when author is sole candidate (#58) (28790e7)

## [0.5.0] - 2026-02-10

### Features

- **workflows**: add reusable pr-auto-assign and pr-labeler (#53) (fd59e18)

## [0.4.1] - 2026-02-10

### Bug Fixes

- **lint**: add markdownlint config for MD013/MD024 (#50) (0073e65)
- **release**: lintro Docker permissions and v0.51.0 update (#49) (7e8aed1)
- **release**: let lintro auto-detect tools for fmt and chk (#48) (96bad24)
- **release**: add lintro formatting to version PR workflow (#47) (5cdd1e0)

## [0.4.0] - 2026-02-09

### Features

- **release**: adopt two-stage release-PR workflow (#43) (a3a0bba)

### Bug Fixes

- **release**: prevent changelog data loss in version PR workflow (#45) (974b2e1)

### Previously Unreleased

- Comprehensive BATS shell testing infrastructure ([#37])
- Advanced CI features including Docker, deploy-pages, and Homebrew workflows ([#12])
- Testing and publishing infrastructure with PyPI, npm, and gem support ([#11])
- Comprehensive testing and coverage infrastructure ([#8])
- SBOM generation and supply chain security actions ([#7])
- Release automation actions and reusable workflow ([#6])
- Quality workflow and linting infrastructure ([#5])
- PR comment and coverage reporting composite actions ([#4])
- Security composite actions with runner hardening and egress audit ([#3])
- Setup composite actions for Python, Node, Rust, and environment ([#2])
- Foundation structure and core shell libraries ([#1])

[Unreleased]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.6.3...HEAD
[0.6.3]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.6.2...v0.6.3
[0.6.2]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/lgtm-hq/lgtm-ci/compare/v0.3.0...v0.4.0
[#37]: https://github.com/lgtm-hq/lgtm-ci/pull/37
[#12]: https://github.com/lgtm-hq/lgtm-ci/pull/12
[#11]: https://github.com/lgtm-hq/lgtm-ci/pull/11
[#8]: https://github.com/lgtm-hq/lgtm-ci/pull/8
[#7]: https://github.com/lgtm-hq/lgtm-ci/pull/7
[#6]: https://github.com/lgtm-hq/lgtm-ci/pull/6
[#5]: https://github.com/lgtm-hq/lgtm-ci/pull/5
[#4]: https://github.com/lgtm-hq/lgtm-ci/pull/4
[#3]: https://github.com/lgtm-hq/lgtm-ci/pull/3
[#2]: https://github.com/lgtm-hq/lgtm-ci/pull/2
[#1]: https://github.com/lgtm-hq/lgtm-ci/pull/1
