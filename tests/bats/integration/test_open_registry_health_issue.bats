#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Integration tests for open-registry-health-issue maintenance script

load "../../helpers/common"
load "../../helpers/mocks"

SCRIPT="${PROJECT_ROOT}/scripts/ci/maintenance/open-registry-health-issue.sh"

setup() {
	setup_temp_dir
	save_path
	export LIB_DIR
	export BATS_TEST_TMPDIR
	export PROJECT_ROOT
	export SCRIPT
	export GH_TOKEN=test-token
	export GITHUB_REPOSITORY=lgtm-hq/lgtm-ci
	export GITHUB_RUN_ID=12345
}

teardown() {
	restore_path
	teardown_temp_dir
}

@test "open-registry-health-issue: opens issue when none exists" {
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	cat >"${BATS_TEST_TMPDIR}/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> '${BATS_TEST_TMPDIR}/mock_calls_gh'
case "\$*" in
	*label*view*registry-health-check*)
		[[ -f '${BATS_TEST_TMPDIR}/mock_label_registry-health-check' ]] && exit 0
		exit 1
		;;
	*label*create*registry-health-check*)
		touch '${BATS_TEST_TMPDIR}/mock_label_registry-health-check'
		exit 0
		;;
	*issue*list*)
		echo "0"
		exit 0
		;;
	*issue*create*)
		echo "https://github.com/lgtm-hq/lgtm-ci/issues/99"
		exit 0
		;;
	*)
		exit 1
		;;
esac
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
	export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"

	run bash -c '
		export PATH="'"$PATH"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "Opened registry health issue"
	run grep -F "registry-health-check" "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_success
}

@test "open-registry-health-issue: skips when an open issue already exists" {
	mock_command_multi "gh" '
		*issue*list*) echo "1";;
		*) exit 1;;
	'

	run bash -c '
		export PATH="'"$PATH"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	assert_output --partial "Open registry health issue already exists"
}

@test "open-registry-health-issue: fails when duplicate check output is invalid" {
	mock_command_multi "gh" '
		*issue*list*) echo "warning: rate limit";;
		*) exit 1;;
	'

	run bash -c '
		export PATH="'"$PATH"'"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "Could not check for existing registry health issues"
}

@test "open-registry-health-issue: fails when GITHUB_REPOSITORY is unset" {
	unset GITHUB_REPOSITORY

	run bash -c '
		export PATH="'"$PATH"'"
		bash "$SCRIPT" 2>&1
	'
	assert_failure
	assert_output --partial "GITHUB_REPOSITORY is required"
}

@test "open-registry-health-issue: creates issue in the configured repository" {
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	cat >"${BATS_TEST_TMPDIR}/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> '${BATS_TEST_TMPDIR}/mock_calls_gh'
case "\$*" in
	*label*view*registry-health-check*)
		exit 0
		;;
	*issue*list*)
		echo "0"
		exit 0
		;;
	*issue*create*)
		echo "https://github.com/lgtm-hq/lgtm-ci/issues/99"
		exit 0
		;;
	*)
		exit 1
		;;
esac
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
	export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"

	run bash -c '
		export PATH="'"$PATH"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	run grep -F -- "--repo" "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_success
	run grep -F "lgtm-hq/lgtm-ci" "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_success
}

@test "open-registry-health-issue: ensures ISSUE_LABELS exist before creation" {
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	cat >"${BATS_TEST_TMPDIR}/bin/gh" <<EOF
#!/usr/bin/env bash
echo "\$@" >> '${BATS_TEST_TMPDIR}/mock_calls_gh'
label_state_dir='${BATS_TEST_TMPDIR}/mock_labels'
mkdir -p "\$label_state_dir"
case "\$*" in
	*label*view*)
		for label in registry-health-check ci maintenance; do
			if [[ "\$*" == *"label view \$label"* ]]; then
				[[ -f "\$label_state_dir/\$label" ]] && exit 0
				exit 1
			fi
		done
		exit 1
		;;
	*label*create*)
		for label in registry-health-check ci maintenance; do
			if [[ "\$*" == *"label create \$label"* ]]; then
				touch "\$label_state_dir/\$label"
				exit 0
			fi
		done
		exit 0
		;;
	*issue*list*)
		echo "0"
		exit 0
		;;
	*issue*create*)
		echo "https://github.com/lgtm-hq/lgtm-ci/issues/99"
		exit 0
		;;
	*)
		exit 1
		;;
esac
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
	export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"

	run bash -c '
		export PATH="'"$PATH"'"
		export ISSUE_LABELS="ci,maintenance"
		bash "$SCRIPT" 2>&1
	'
	assert_success
	run grep -F "label create ci" "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_success
	run grep -F "label create maintenance" "${BATS_TEST_TMPDIR}/mock_calls_gh"
	assert_success
}

@test "open-registry-health-issue: tolerates concurrent dedup label creation" {
	mkdir -p "${BATS_TEST_TMPDIR}/bin"
	cat >"${BATS_TEST_TMPDIR}/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${MOCK_CALLS}"
case "$*" in
	*label*view*registry-health-check*)
		if [[ -f "${MOCK_LABEL_EXISTS}" ]]; then
			exit 0
		fi
		exit 1
		;;
	*label*create*registry-health-check*)
		touch "${MOCK_LABEL_EXISTS}"
		echo "label already exists" >&2
		exit 1
		;;
	*issue*list*)
		echo "0"
		exit 0
		;;
	*issue*create*)
		echo "https://github.com/lgtm-hq/lgtm-ci/issues/99"
		exit 0
		;;
	*)
		exit 1
		;;
esac
EOF
	chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
	export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
	export MOCK_CALLS="${BATS_TEST_TMPDIR}/mock_calls_gh"
	export MOCK_LABEL_EXISTS="${BATS_TEST_TMPDIR}/mock_label_exists"

	run bash -c '
		export PATH="'"$PATH"'"
		export MOCK_CALLS="'"$MOCK_CALLS"'"
		export MOCK_LABEL_EXISTS="'"$MOCK_LABEL_EXISTS"'"
		bash "$SCRIPT" 2>&1
	'
	assert_success
}
