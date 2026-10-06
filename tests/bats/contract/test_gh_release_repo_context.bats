#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for repository context on `gh release` steps (#935).
#
# Publisher jobs check out lgtm-ci tooling into .lgtm-ci-tooling/ and never
# the caller (#796), so the working directory is not a git repository. `gh`
# resolves the target repository from the git remote unless `--repo` or
# `GH_REPO` says otherwise, and without either `gh release upload` fails with
# "not a git repository" on every real tag run. Every step that runs
# `gh release` — inline or through a script that does not pass `--repo` —
# must therefore set `GH_REPO` in its `env:`.

load "../../helpers/common"

# Basenames of scripts under scripts/ci/ with at least one non-comment
# `gh release` invocation that does not pass `--repo` on the same line.
_repo_less_release_scripts() {
	grep -rlE '^[^#]*gh release' "${PROJECT_ROOT}/scripts/ci" --include='*.sh' |
		while IFS= read -r script; do
			if grep -E '^[^#]*gh release' "$script" | grep -qvE -- '--repo'; then
				basename "$script"
			fi
		done | sort
}

# The scanner's script list: `;`-separated `<basename>[@<guard line>]`
# entries (BSD awk rejects newlines in -v values). A script that dispatches
# on STEP only reaches `gh release` under one value, so a step running it
# counts as a release step only when it also sets that value; every other
# repo-less script counts on any invocation.
_release_script_patterns() {
	_repo_less_release_scripts | while IFS= read -r script; do
		case "$script" in
		sign-artifact.sh) printf '%s@STEP: upload-release;' "$script" ;;
		*) printf '%s;' "$script" ;;
		esac
	done
}

# Walk the steps of one workflow or action file and print one
# `<line>:<name>:<release>:<gh_repo>` record per step, where `release` is 1
# when the step's non-comment lines mention `gh release` or one of the
# scripts in $2 (`;`-separated `<basename>[@<guard>]` entries, the guard
# being a line the step must also contain), and `gh_repo` is 1 when the
# step's `env:` mapping has a `GH_REPO` key. Steps are the `- ` items two
# columns deeper than a `steps:` key; everything indented past the item
# belongs to it, so `run: |` blocks are read and comment-only lines skipped.
_release_steps() {
	local file="$1" scripts="$2"

	awk -v scripts="$scripts" '
		function indent_of(line, prefix) {
			prefix = line
			sub(/[^ ].*$/, "", prefix)
			return length(prefix)
		}
		function end_step(i) {
			if (in_step) {
				for (i = 1; i <= n; i++) {
					if (seen[i] && (guard[i] == "" || guarded[i])) { release = 1 }
				}
				printf("%d:%s:%d:%d\n", step_line, step_name, release, gh_repo)
			}
			in_step = 0
			release = 0
			gh_repo = 0
			env_indent = -1
			step_name = ""
			for (i = 1; i <= n; i++) { seen[i] = 0; guarded[i] = 0 }
		}
		BEGIN {
			n = split(scripts, list, ";")
			for (i = 1; i <= n; i++) {
				guard[i] = ""
				at = index(list[i], "@")
				if (at > 0) {
					guard[i] = substr(list[i], at + 1)
					list[i] = substr(list[i], 1, at - 1)
				}
				if (list[i] == "") { n = i - 1; break }
			}
			steps_indent = -1
			env_indent = -1
		}
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		{
			ind = indent_of($0)
			if ($0 ~ /^[[:space:]]*steps:[[:space:]]*$/) {
				end_step()
				steps_indent = ind
				next
			}
			if (steps_indent >= 0 && ind <= steps_indent) {
				end_step()
				steps_indent = -1
				next
			}
			if (steps_indent >= 0 && ind == steps_indent + 2 && $0 ~ /^[[:space:]]*- /) {
				end_step()
				in_step = 1
				step_line = NR
				body = $0
				sub(/^[[:space:]]*- /, "", body)
				if (body ~ /^name:/) {
					step_name = body
					sub(/^name:[[:space:]]*/, "", step_name)
				}
			}
			if (!in_step) { next }
			if ($0 ~ /^[[:space:]]+name:/ && step_name == "") {
				step_name = $0
				sub(/^[[:space:]]+name:[[:space:]]*/, "", step_name)
			}
			if ($0 ~ /^[[:space:]]+env:[[:space:]]*$/) {
				env_indent = ind
			} else if (env_indent >= 0 && ind <= env_indent) {
				env_indent = -1
			}
			if (env_indent >= 0 && ind == env_indent + 2 && $0 ~ /^[[:space:]]+GH_REPO:/) {
				gh_repo = 1
			}
			line = $0
			sub(/[[:space:]]+#.*$/, "", line)
			if (line ~ /gh release/) { release = 1 }
			for (i = 1; i <= n; i++) {
				if (index(line, list[i]) > 0) { seen[i] = 1 }
				if (guard[i] != "" && index(line, guard[i]) > 0) { guarded[i] = 1 }
			}
		}
		END { end_step() }
	' "$file"
}

_publisher_files() {
	{
		find "${PROJECT_ROOT}/.github/workflows" -name '*.yml'
		find "${PROJECT_ROOT}/.github/actions" -name 'action.yml'
	} | sort
}

@test "gh-release: the SBOM upload and signature upload scripts are the repo-less callers" {
	run _repo_less_release_scripts
	assert_success
	assert_line "sign-artifact.sh"
	assert_line "upload-sbom-release-assets.sh"
	# create-github-release.sh passes --repo "$REPO" explicitly and must not
	# appear here; a new script that drops --repo joins the list and is then
	# held to the GH_REPO contract below.
	refute_output --partial "create-github-release.sh"
}

@test "gh-release: upload-sbom-release-assets.sh refuses to run without GH_REPO" {
	run env GH_TOKEN=t RELEASE_TAG=v1 ARTIFACT_NAME=sbom SBOM_ARTIFACT_DIR=. \
		bash "${PROJECT_ROOT}/scripts/ci/actions/upload-sbom-release-assets.sh"
	assert_failure
	assert_output --partial "GH_REPO is required"
}

@test "gh-release: reusable-sbom-release-upload sets GH_REPO on the upload step" {
	run _release_steps \
		"${PROJECT_ROOT}/.github/workflows/reusable-sbom-release-upload.yml" \
		"$(_release_script_patterns)"
	assert_success
	assert_output --partial ':Upload SBOM to GitHub Release:1:1'
	run grep -E '^[[:space:]]+GH_REPO: \$\{\{ github\.repository \}\}$' \
		"${PROJECT_ROOT}/.github/workflows/reusable-sbom-release-upload.yml"
	assert_success
}

@test "gh-release: sign-artifact sets GH_REPO on its release upload step only" {
	run _release_steps "${PROJECT_ROOT}/.github/actions/sign-artifact/action.yml" \
		"$(_release_script_patterns)"
	assert_success
	assert_output --partial ':Upload signatures to release:1:1'
	# The sign and summary steps run the same script under another STEP and
	# never reach gh; the guard keeps them out of the contract.
	assert_output --partial ':Sign artifacts:0:0'
	assert_output --partial ':Generate summary:0:0'
}

@test "gh-release: no step runs gh release without GH_REPO in its env" {
	local scripts file violations=() checked=0
	scripts="$(_release_script_patterns)"
	while IFS= read -r file; do
		while IFS=: read -r line name release gh_repo; do
			[[ "$release" == "1" ]] || continue
			checked=$((checked + 1))
			if [[ "$gh_repo" != "1" ]]; then
				violations+=("${file#"${PROJECT_ROOT}"/}:${line} (${name:-unnamed})")
			fi
		done < <(_release_steps "$file" "$scripts")
	done < <(_publisher_files)
	if [[ ${#violations[@]} -gt 0 ]]; then
		printf 'gh release step without GH_REPO: %s\n' "${violations[@]}" >&2
		return 1
	fi
	# The scanner must actually see the known steps or a regression in it
	# would pass vacuously.
	[[ "$checked" -ge 2 ]]
}

@test "gh-release: scanner flags a gh release step that lacks GH_REPO" {
	local sample="${BATS_TEST_TMPDIR}/sample.yml"
	cat >"$sample" <<'YAML'
jobs:
  publish:
    steps:
      - name: Covered
        env:
          GH_TOKEN: x
          GH_REPO: owner/repo
        run: gh release upload v1 file
      - name: Uncovered
        env:
          GH_TOKEN: x
        run: |
          echo start
          gh release upload v1 file
      - name: Script
        run: bash .lgtm-ci-tooling/scripts/ci/actions/upload-sbom-release-assets.sh
      - name: Guarded script, other step
        env:
          STEP: sign
        run: $SCRIPTS_DIR/ci/actions/sign-artifact.sh
      - name: Guarded script, upload step
        env:
          STEP: upload-release
        run: $SCRIPTS_DIR/ci/actions/sign-artifact.sh
      - name: Nested GH_REPO does not count
        with:
          GH_REPO: owner/repo
        run: gh release upload v1 file
      - name: Unrelated
        run: echo done # gh release upload happens elsewhere
      - name: Comment only
        run: |
          # gh release upload
          true
YAML
	run _release_steps "$sample" "$(_release_script_patterns)"
	assert_success
	assert_output --partial ':Covered:1:1'
	assert_output --partial ':Uncovered:1:0'
	assert_output --partial ':Script:1:0'
	assert_output --partial ':Guarded script, other step:0:0'
	assert_output --partial ':Guarded script, upload step:1:0'
	assert_output --partial ':Nested GH_REPO does not count:1:0'
	assert_output --partial ':Unrelated:0:0'
	assert_output --partial ':Comment only:0:0'
}
