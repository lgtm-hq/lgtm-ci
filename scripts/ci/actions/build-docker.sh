#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Dispatch Docker build action steps to per-step scripts in docker/
#
# Required environment variables:
#   STEP - Which step to run: setup, build, push, metadata, parse-tags, summary,
#          set-output-digest, classify, record-digest, smoke-test, smoke-test-local,
#          health-check, health-check-local, resolve-local-health-check-image,
#          resolve-local-scan-image, sign-image,
#          merge-manifests, verify-published, summarize-blocked-egress
#
# Each step's environment variable contract is documented in the corresponding
# scripts/ci/actions/docker/<step>.sh script. The smoke-test and
# smoke-test-local steps share docker/smoke-test.sh via LOCAL=true/false.

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

case "$STEP" in
setup | build | push | metadata | parse-tags | set-output-digest | classify | \
	record-digest | resolve-local-health-check-image | resolve-local-scan-image | \
	health-check | health-check-local | merge-manifests | verify-published | \
	sign-image | summary | summarize-blocked-egress)
	# shellcheck disable=SC1090
	source "$SCRIPT_DIR/docker/${STEP}.sh"
	;;

smoke-test)
	export LOCAL=false
	# shellcheck source=docker/smoke-test.sh
	source "$SCRIPT_DIR/docker/smoke-test.sh"
	;;

smoke-test-local)
	export LOCAL=true
	# shellcheck source=docker/smoke-test.sh
	source "$SCRIPT_DIR/docker/smoke-test.sh"
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
