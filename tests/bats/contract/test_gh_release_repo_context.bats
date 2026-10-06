#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for repository context on `gh release` steps (#935).
#
# Publisher jobs check out lgtm-ci tooling into .lgtm-ci-tooling/ and never
# the caller (#796), so the working directory is not a git repository. `gh`
# resolves the target repository from the git remote unless `--repo` or
# `GH_REPO` says otherwise, and without either `gh release upload` fails with
# "not a git repository" on every real tag run. Every step that runs
# `gh release` — inline without `--repo`, or through a script that does not
# pass `--repo` — must therefore set `GH_REPO` in its `env:`.
#
# The scanner is line-structured, not a YAML parser. It reads block-style
# steps (`- name:` items under a `steps:` key, indentless or indented) with
# block-style `env:` mappings. Flow-style steps or `env: {GH_REPO: ...}` are
# not recognised as setting GH_REPO and are flagged — the strict direction —
# so a workflow written that way fails this test rather than slipping past it.

load "../../helpers/common"

# Does this `gh release` command pass `--repo`/`-R`? Only the command's own
# segment counts: the text from `gh release` up to the next `&&`, `||`, `;`
# or `|`, so a flag in a later command (`&& echo "--repo x"`) is not credited
# to gh. Shared by the script discovery and the step scanner below.
_GH_RELEASE_HAS_REPO_AWK='
	function gh_release_has_repo(line, seg, cut) {
		seg = substr(line, index(line, "gh release"))
		cut = match(seg, /(&&|\|\||;|\|)/)
		if (cut > 0) { seg = substr(seg, 1, cut - 1) }
		return seg ~ /(--repo|-R)([[:space:]]|=)/
	}
'

# Basenames of scripts under scripts/ci/ with at least one non-comment
# `gh release` invocation that does not pass `--repo`/`-R`.
_repo_less_release_scripts() {
	grep -rlE '^[^#]*gh release' "${PROJECT_ROOT}/scripts/ci" --include='*.sh' |
		while IFS= read -r script; do
			if awk "$_GH_RELEASE_HAS_REPO_AWK"'
				/^[[:space:]]*#/ { next }
				/gh release/ && !gh_release_has_repo($0) { found = 1; exit }
				END { exit !found }
			' "$script"; then
				basename "$script"
			fi
		done | sort
}

# The scanner's script list: `;`-separated `<basename>[@<KEY>=<value>]`
# entries (BSD awk rejects newlines in -v values). A script that dispatches
# on STEP only reaches `gh release` under one value, so a step running it
# counts as a release step only when its env sets exactly that value; every
# other repo-less script counts on any invocation.
_release_script_patterns() {
	_repo_less_release_scripts | while IFS= read -r script; do
		case "$script" in
		sign-artifact.sh) printf '%s@STEP=upload-release;' "$script" ;;
		*) printf '%s;' "$script" ;;
		esac
	done
}

# Walk the steps of one workflow or action file and print one
# `<line>:<release>:<gh_repo>:<name>` record per step (name last: it may
# contain colons). `release` is 1 when a non-comment line of the step runs
# `gh release` without `--repo`/`-R`, or names one of the scripts in $2 whose
# guard (if any) the step's env satisfies. `gh_repo` is 1 when the step's own
# `env:` mapping — at the step's key indent, so neither a `with:` → `env:`
# input nor text inside a `run: |` block counts — has a `GH_REPO` key.
_release_steps() {
	local file="$1" scripts="$2"

	awk -v scripts="$scripts" "$_GH_RELEASE_HAS_REPO_AWK"'
		function indent_of(line, prefix) {
			prefix = line
			sub(/[^ ].*$/, "", prefix)
			return length(prefix)
		}
		# `KEY: value` with optional quotes around the value -> "KEY=value".
		function env_pair(line, k, v) {
			k = line
			sub(/^[[:space:]]+/, "", k)
			v = k
			sub(/:.*$/, "", k)
			sub(/^[^:]*:[[:space:]]*/, "", v)
			sub(/[[:space:]]+#.*$/, "", v)
			gsub(/^["'"'"']|["'"'"']$/, "", v)
			return k "=" v
		}
		function end_step(i) {
			if (in_step) {
				for (i = 1; i <= n; i++) {
					if (seen[i] && (guard[i] == "" || guarded[i])) { release = 1 }
				}
				printf("%d:%d:%d:%s\n", step_line, release, gh_repo, step_name)
			}
			in_step = 0
			release = 0
			gh_repo = 0
			env_open = 0
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
			item_indent = -1
			key_indent = -1
		}
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		{
			ind = indent_of($0)
			is_item = ($0 ~ /^[[:space:]]*- /)
			# A `steps:` key opens a step list unless it sits inside a step
			# (a heredoc or block scalar inside `run: |`, say).
			if ($0 ~ /^[[:space:]]*steps:[[:space:]]*$/ && (!in_step || ind <= item_indent)) {
				end_step()
				steps_indent = ind
				item_indent = -1
				next
			}
			if (steps_indent < 0) { next }
			if (item_indent < 0) {
				# First item fixes the list indent (indentless or +2).
				if (is_item && ind >= steps_indent) {
					item_indent = ind
				} else {
					steps_indent = -1
					next
				}
			}
			# Anything at or above the item indent that is not an item ends
			# the list (a sibling job key, the next job, ...).
			if (ind < item_indent || (ind == item_indent && !is_item)) {
				end_step()
				steps_indent = -1
				item_indent = -1
				next
			}
			if (ind == item_indent && is_item) {
				end_step()
				in_step = 1
				step_line = NR
				key_indent = item_indent + 2
				body = $0
				sub(/^[[:space:]]*- /, "", body)
				if (body ~ /^name:/) {
					step_name = body
					sub(/^name:[[:space:]]*/, "", step_name)
				}
			}
			if (!in_step) { next }
			if (ind == key_indent && $0 ~ /^[[:space:]]+name:/ && step_name == "") {
				step_name = $0
				sub(/^[[:space:]]+name:[[:space:]]*/, "", step_name)
			}
			if (ind == key_indent && $0 ~ /^[[:space:]]+env:[[:space:]]*$/) {
				env_open = 1
			} else if (env_open && ind <= key_indent) {
				env_open = 0
			}
			if (env_open && ind == key_indent + 2) {
				if ($0 ~ /^[[:space:]]+GH_REPO:/) { gh_repo = 1 }
				pair = env_pair($0)
				for (i = 1; i <= n; i++) {
					if (guard[i] != "" && pair == guard[i]) { guarded[i] = 1 }
				}
			}
			line = $0
			sub(/[[:space:]]+#.*$/, "", line)
			if (line ~ /gh release/ && !gh_release_has_repo(line)) { release = 1 }
			for (i = 1; i <= n; i++) {
				if (index(line, list[i]) > 0) { seen[i] = 1 }
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

# A step names the script it runs, never the library that script sources, so
# a `gh release` call moved into scripts/ci/lib/ would be invisible to the
# step scanner. Keep such calls in entry-point scripts.
@test "gh-release: no shared library under scripts/ci/lib runs gh release" {
	run grep -rlE '^[^#]*gh release' "${PROJECT_ROOT}/scripts/ci/lib" --include='*.sh'
	assert_failure
	refute_output
}

@test "gh-release: reusable-sbom-release-upload sets GH_REPO on the upload step" {
	run _release_steps \
		"${PROJECT_ROOT}/.github/workflows/reusable-sbom-release-upload.yml" \
		"$(_release_script_patterns)"
	assert_success
	assert_output --partial ':1:1:Upload SBOM to GitHub Release'
	run grep -E '^[[:space:]]+GH_REPO: \$\{\{ github\.repository \}\}$' \
		"${PROJECT_ROOT}/.github/workflows/reusable-sbom-release-upload.yml"
	assert_success
}

@test "gh-release: sign-artifact sets GH_REPO on its release upload step only" {
	run _release_steps "${PROJECT_ROOT}/.github/actions/sign-artifact/action.yml" \
		"$(_release_script_patterns)"
	assert_success
	assert_output --partial ':1:1:Upload signatures to release'
	# The sign and summary steps run the same script under another STEP and
	# never reach gh; the guard keeps them out of the contract.
	assert_output --partial ':0:0:Sign artifacts'
	assert_output --partial ':0:0:Generate summary'
}

@test "gh-release: no step runs gh release without GH_REPO in its env" {
	local scripts file violations=() checked=0
	scripts="$(_release_script_patterns)"
	while IFS= read -r file; do
		while IFS=: read -r line release gh_repo name; do
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
      - name: Guarded script, quoted upload step
        env:
          STEP: "upload-release"
        run: $SCRIPTS_DIR/ci/actions/sign-artifact.sh
      - name: Guarded script, prefix is not a match
        env:
          STEP: upload-release-other
        run: $SCRIPTS_DIR/ci/actions/sign-artifact.sh
      - name: Nested GH_REPO does not count
        with:
          GH_REPO: owner/repo
          env:
            GH_REPO: owner/repo
        run: gh release upload v1 file
      - name: GH_REPO inside the run block does not count
        run: |
          cat <<'EOF'
          env:
            GH_REPO: owner/repo
          EOF
          gh release upload v1 file
      - name: Explicit --repo is exempt
        run: gh release upload v1 file --repo owner/repo
      - name: Explicit -R is exempt
        run: gh release upload v1 file -R owner/repo
      - name: A --repo in a later command is not gh's
        run: gh release upload v1 file && echo "--repo owner/repo"
      - name: A --repo after a semicolon is not gh's
        run: gh release upload v1 file; true --repo owner/repo
      - name: Unrelated
        run: echo done # gh release upload happens elsewhere
      - name: Comment only
        run: |
          # gh release upload
          true
      - name: 'Release: colon in name'
        run: gh release upload v1 file
      - name: After a steps key inside a run block
        run: |
          cat <<'EOF'
          steps:
            - name: not a step
          EOF
          gh release upload v1 file
    env:
      GH_REPO: job-level-does-not-count
  indentless:
    steps:
    - name: Indentless covered
      env:
        GH_REPO: owner/repo
      run: gh release upload v1 file
    - name: Indentless uncovered
      run: gh release upload v1 file
    timeout-minutes: 5
YAML
	run _release_steps "$sample" "$(_release_script_patterns)"
	assert_success
	assert_output --partial ':1:1:Covered'
	assert_output --partial ':1:0:Uncovered'
	assert_output --partial ':1:0:Script'
	assert_output --partial ':0:0:Guarded script, other step'
	assert_output --partial ":1:0:Guarded script, upload step"
	assert_output --partial ':1:0:Guarded script, quoted upload step'
	assert_output --partial ':0:0:Guarded script, prefix is not a match'
	assert_output --partial ':1:0:Nested GH_REPO does not count'
	assert_output --partial ':1:0:GH_REPO inside the run block does not count'
	assert_output --partial ':0:0:Explicit --repo is exempt'
	assert_output --partial ':0:0:Explicit -R is exempt'
	assert_output --partial ":1:0:A --repo in a later command is not gh's"
	assert_output --partial ":1:0:A --repo after a semicolon is not gh's"
	assert_output --partial ':0:0:Unrelated'
	assert_output --partial ':0:0:Comment only'
	assert_output --partial ":1:0:'Release: colon in name'"
	assert_output --partial ':1:0:After a steps key inside a run block'
	assert_output --partial ':1:1:Indentless covered'
	assert_output --partial ':1:0:Indentless uncovered'
}
