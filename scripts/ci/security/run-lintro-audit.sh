#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run osv-scanner via lintro in Docker and generate a security PR comment.
#
# Required environment variables:
#   LINTRO_IMAGE   Pinned ghcr.io/lgtm-hq/py-lintro reference
#
# Optional environment variables:
#   WORKSPACE              Absolute path to mount at /code (default: pwd)
#   OSV_RESULTS            JSON output path (default: osv-results.json)
#   OSV_OUTPUT             Scanner log path (default: osv-output.txt)
#   COMMENT_FILE           PR comment artifact path (default: security-audit-comment.txt)
#   COMMENT_TITLE          Report heading (default: Security Audit)
#   FORMAT_SCRIPT          Path to format-security-comment.py (default: sibling script)
#   MAP_HOST_USER          true|false (default: true on GitHub Actions)
#
# Python: the result check and FORMAT_SCRIPT run on python3 from PATH, 3.11
# or newer (lib/python.sh, pin_python_from_path); PYTHON from the
# environment is ignored, as it was when the script called python3
# directly. Checked once, before the image is pulled.
#
# Exit status:
#   0   - the audit passed
#   1   - vulnerabilities found, the scan failed, or the comment could not
#         be formatted
#   69  - python3 is missing or older than 3.11 (one ::error:: line); no
#         scan ran, and the step outputs say audit-failed=1, exit-code=69
#   other non-zero - docker pull's own status when the image cannot be
#         pulled

set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
	cat <<'EOF'
run-lintro-audit.sh — run osv-scanner via lintro Docker and write PR comment artifact.

Requires: LINTRO_IMAGE=ghcr.io/lgtm-hq/py-lintro@sha256:...

Optional: WORKSPACE, OSV_RESULTS, OSV_OUTPUT, COMMENT_FILE, COMMENT_TITLE,
FORMAT_SCRIPT, MAP_HOST_USER
EOF
	exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

if [[ -f "$LIB_DIR/log.sh" ]]; then
	# shellcheck source=../lib/log.sh
	source "$LIB_DIR/log.sh"
fi

if [[ -f "$LIB_DIR/github/format.sh" ]]; then
	# shellcheck source=../lib/github/format.sh
	source "$LIB_DIR/github/format.sh"
fi

# results.v1 contract (#1080): the audit leg writes results.json like every
# other runner; findings land under counts.failed.
# shellcheck source=../lib/testing/results.sh
source "$LIB_DIR/testing/results.sh"
# shellcheck source=../lib/testing/parse/osv.sh
source "$LIB_DIR/testing/parse/osv.sh"
# shellcheck source=../lib/python.sh
source "$LIB_DIR/python.sh"
# COMMENT_TITLE is a caller input: the heading inserts it as sanitised text
# (#1676, docs/comment-sanitize.md). The body comes from
# format-security-comment.py, which sanitises what it inserts.
# shellcheck source=../lib/github/comment_sanitize.sh
source "$LIB_DIR/github/comment_sanitize.sh"

: "${WORKSPACE:=$(pwd)}"
: "${OSV_RESULTS:=osv-results.json}"
: "${OSV_OUTPUT:=osv-output.txt}"
: "${COMMENT_FILE:=security-audit-comment.txt}"
: "${COMMENT_TITLE:=Security Audit}"
: "${FORMAT_SCRIPT:=$SCRIPT_DIR/format-security-comment.py}"
: "${MAP_HOST_USER:=}"
if [[ -z "${MAP_HOST_USER}" ]] && [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
	MAP_HOST_USER=true
fi

write_audit_github_output() {
	local has_vulns="${1:-0}"
	local audit_failed="${2:-0}"
	local format_failed="${3:-0}"
	local exit_code="${4:-0}"

	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		{
			echo "has-vulns=${has_vulns}"
			echo "audit-failed=${audit_failed}"
			echo "format-failed=${format_failed}"
			echo "exit-code=${exit_code}"
			if [[ "${exit_code}" -eq 0 ]]; then
				echo "status=passed"
			else
				echo "status=failed"
			fi
		} >>"${GITHUB_OUTPUT}"
	fi
	AUDIT_OUTPUTS_WRITTEN=1
}

# Any failure that ends the script before its outputs are written (a missing
# setting, an unwritable comment file, a helper that fails) still leaves the
# step outputs of a failed audit, so a later step never reads "no outputs"
# as a pass.
AUDIT_OUTPUTS_WRITTEN=0
write_audit_outputs_on_failure() {
	local rc=$?
	if [[ "${rc}" -ne 0 && "${AUDIT_OUTPUTS_WRITTEN}" -eq 0 ]]; then
		write_audit_github_output 0 1 0 "${rc}" || true
	fi
}
trap write_audit_outputs_on_failure EXIT

: "${LINTRO_IMAGE:?LINTRO_IMAGE is required}"

# python3 from PATH, 3.11 or newer, pinned to its absolute path for both
# run_python calls below; checked before the pull so a refused interpreter
# costs no image download (#1591).
PYTHON_RC=0
pin_python_from_path || PYTHON_RC=$?
if [[ "${PYTHON_RC}" -ne 0 ]]; then
	write_audit_github_output 0 1 0 "${PYTHON_RC}"
	exit "${PYTHON_RC}"
fi

log_info "Pulling Lintro image: ${LINTRO_IMAGE}"
set +e
PULL_OUTPUT="$(docker pull "${LINTRO_IMAGE}" 2>&1)"
PULL_EC=$?
set -e
if [[ "${PULL_EC}" -ne 0 ]]; then
	log_error "Failed to pull Lintro image ${LINTRO_IMAGE}: ${PULL_OUTPUT}"
	write_audit_github_output 0 1 0 1
	exit "${PULL_EC}"
fi
printf '%s\n' "${PULL_OUTPUT}"

rm -f "${WORKSPACE}/${OSV_RESULTS}" "${WORKSPACE}/${OSV_OUTPUT}"

log_info "Running osv-scanner via lintro in Docker..."

declare -a docker_args=(
	docker run --rm
	-e HOME=/tmp
	-v "${WORKSPACE}:/code"
	-w /code
)
if [[ "${MAP_HOST_USER}" == "true" ]]; then
	docker_args+=(--user "$(id -u):$(id -g)")
fi
docker_args+=("${LINTRO_IMAGE}")

OSV_EXIT_CODE=0
set +e
set -o pipefail
"${docker_args[@]}" \
	lintro check . --tools osv_scanner \
	--output-format json --output "/code/${OSV_RESULTS}" \
	2>&1 | tee "${WORKSPACE}/${OSV_OUTPUT}"
OSV_EXIT_CODE="${PIPESTATUS[0]}"
set +o pipefail
set -e

PARSE_OK=0
HAS_VULNS=0
if [[ -f "${WORKSPACE}/${OSV_RESULTS}" ]]; then
	PYRC=0
	run_python -I -c "
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path))
    if not isinstance(data, dict):
        print(f'Unexpected JSON root (not a dict) in {path}', file=sys.stderr)
        sys.exit(2)
    result = next(
        (x for x in data.get('results', []) if isinstance(x, dict) and x.get('tool') == 'osv_scanner'),
        None,
    )
    if result is None:
        print(f'No osv_scanner result in {path}', file=sys.stderr)
        sys.exit(2)
    # A malformed issues_count (#1676) counts the issues list; with none, the
    # results are unreadable, never clean.
    # lintro always writes issues_count; a missing one is unreadable too.
    # A longer issues list wins over the count.
    count = result.get('issues_count')
    issues = result.get('issues')
    listed = len(issues) if isinstance(issues, list) else 0
    if isinstance(count, float) and count.is_integer():
        count = int(count)
    if isinstance(count, bool) or not isinstance(count, int) or not 0 <= count < 10**9:
        if not listed:
            print(f'issues_count in {path} is not a number', file=sys.stderr)
            sys.exit(2)
        count = listed
    sys.exit(0 if max(count, listed) > 0 else 1)
except Exception as exc:
    print(f'Failed to interpret {path}: {exc!r}', file=sys.stderr)
    sys.exit(2)
" "${WORKSPACE}/${OSV_RESULTS}" || PYRC=$?
	case "${PYRC}" in
	0)
		PARSE_OK=1
		HAS_VULNS=1
		;;
	1) PARSE_OK=1 ;;
	*) PARSE_OK=0 ;;
	esac
fi

AUDIT_FAILED=0
if [[ "${OSV_EXIT_CODE}" -ne 0 ]] && [[ "${HAS_VULNS}" -eq 0 ]]; then
	log_info "osv-scanner exited non-zero but no valid vulnerability data found"
	AUDIT_FAILED=1
fi
if [[ "${OSV_EXIT_CODE}" -eq 0 ]] && [[ "${PARSE_OK}" -eq 0 ]]; then
	log_error "osv-scanner exited 0 but results are missing or unparseable"
	AUDIT_FAILED=1
fi

format_err="$(mktemp)"
FORMAT_FAILED=0
if ! COMMENT_BODY="$(
	run_python -I "${FORMAT_SCRIPT}" "${WORKSPACE}/${OSV_RESULTS}" 2>"${format_err}"
)"; then
	log_error "format-security-comment.py failed:"
	cat "${format_err}" >&2
	COMMENT_BODY="Failed to format security audit results. See CI logs for details."
	FORMAT_FAILED=1
fi
rm -f "${format_err}"

if [[ "${AUDIT_FAILED}" -eq 1 ]]; then
	STATUS="⚠️ AUDIT FAILED"
elif [[ "${FORMAT_FAILED}" -eq 1 ]]; then
	STATUS="⚠️ FORMAT FAILED"
elif [[ "${HAS_VULNS}" -eq 1 ]]; then
	STATUS="⚠️ VULNERABILITIES FOUND"
else
	STATUS="✅ PASSED"
fi

BUILD_URL=""
if declare -f get_github_actions_run_url &>/dev/null; then
	BUILD_URL=$(get_github_actions_run_url || true)
fi
BUILD_LINK_BLOCK=""
if [[ -n "${BUILD_URL}" ]]; then
	BUILD_LINK_BLOCK="

---

[View full build details](${BUILD_URL})"
fi

{
	printf '%s\n\n' "## 🔐 $(printf '%s' "${COMMENT_TITLE}" | comment_sanitize text) Report"
	printf '%s\n\n' "### 📊 Status: ${STATUS}"
	printf '%s\n' "${COMMENT_BODY}"
	printf '%s\n' "${BUILD_LINK_BLOCK}"
	printf '\n<sub>Generated by lgtm-ci security audit workflow</sub>\n'
} >"${WORKSPACE}/${COMMENT_FILE}"

# results.v1 document (#1080), written before the clean-run cleanup below so
# the scanner JSON it summarises is still present. A scan or format failure
# is status error; findings are failed; a clean scan is passed.
: "${RESULTS_OUTPUT:=${WORKSPACE}/$(results_v1_path security-audit default)}"
results_parse_status="ok"
if [[ "${AUDIT_FAILED}" -eq 1 ]] || [[ "${FORMAT_FAILED}" -eq 1 ]]; then
	results_parse_status="invalid"
fi
results_artifacts="comment=${COMMENT_FILE}"$'\n'
if [[ -f "${WORKSPACE}/${OSV_RESULTS}" ]]; then
	results_artifacts+="report=${OSV_RESULTS}"$'\n'
fi
mkdir -p "$(dirname "${RESULTS_OUTPUT}")"
RESULTS_ARTIFACTS="${results_artifacts}" EXIT_CODE="${OSV_EXIT_CODE}" \
	osv_results_v1 "${WORKSPACE}/${OSV_RESULTS}" >"${RESULTS_OUTPUT}"
if [[ "${results_parse_status}" != "ok" ]]; then
	# The wrapper only sees the scanner JSON; fold the audit/format verdict in.
	jq '.status = "error"' "${RESULTS_OUTPUT}" >"${RESULTS_OUTPUT}.tmp" &&
		mv "${RESULTS_OUTPUT}.tmp" "${RESULTS_OUTPUT}"
fi
results_v1_validate "${RESULTS_OUTPUT}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	echo "results-json=${RESULTS_OUTPUT}" >>"${GITHUB_OUTPUT}"
fi
log_info "results.v1 written: ${RESULTS_OUTPUT}"

if [[ "${HAS_VULNS}" -eq 0 ]] && [[ "${AUDIT_FAILED}" -eq 0 ]] && [[ "${FORMAT_FAILED}" -eq 0 ]]; then
	rm -f "${WORKSPACE}/${OSV_RESULTS}" "${WORKSPACE}/${OSV_OUTPUT}"
fi

EXIT_CODE=0
if [[ "${AUDIT_FAILED}" -eq 1 ]] || [[ "${FORMAT_FAILED}" -eq 1 ]] || [[ "${HAS_VULNS}" -eq 1 ]]; then
	EXIT_CODE=1
fi

write_audit_github_output "${HAS_VULNS}" "${AUDIT_FAILED}" "${FORMAT_FAILED}" "${EXIT_CODE}"

if [[ "${AUDIT_FAILED}" -eq 1 ]]; then
	log_error "Security audit failed (tool/scan error)"
	exit 1
elif [[ "${FORMAT_FAILED}" -eq 1 ]]; then
	log_error "Security audit comment formatting failed"
	exit 1
elif [[ "${HAS_VULNS}" -eq 1 ]]; then
	log_error "Security audit found vulnerabilities"
	exit 1
fi

log_success "Security audit passed"
exit 0
