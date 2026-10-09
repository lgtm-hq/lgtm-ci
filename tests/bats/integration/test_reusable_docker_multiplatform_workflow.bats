#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
# Purpose: Contract tests for the split multi-arch Docker path: the facade
#          reusable-docker-multiplatform.yml (#381) and, since #1081, the
#          read-only reusable-docker-multiplatform-validate.yml and the
#          internal reusable-docker-multiplatform-publish.yml it calls.

load "../../helpers/common"

WORKFLOW="${PROJECT_ROOT}/.github/workflows/reusable-docker-multiplatform.yml"
VALIDATE="${PROJECT_ROOT}/.github/workflows/reusable-docker-multiplatform-validate.yml"
PUBLISH="${PROJECT_ROOT}/.github/workflows/reusable-docker-multiplatform-publish.yml"
UNION="${PROJECT_ROOT}/scripts/ci/docs/validate-caller-permissions.py"

# Print the body of one top-level job (from `  <id>:` to the next job).
_job() {
	awk -v id="$2" '
		$0 == "  " id ":" { on = 1; print; next }
		on && /^  [a-z][a-z0-9-]*:$/ { exit }
		on { print }
	' "$1"
}

@test "reusable-docker-multiplatform: all three files require the classify matrix input" {
	local f
	for f in "$WORKFLOW" "$VALIDATE" "$PUBLISH"; do
		run awk '
			/^      matrix:$/ { in_input = 1 }
			in_input && /^        required: true$/ { found = 1; exit }
			in_input && /^      [a-z-]+:$/ && !/^      matrix:$/ { in_input = 0 }
			END { exit !found }
		' "$f"
		assert_success
	done
}

# ---------------------------------------------------------------- facade

@test "reusable-docker-multiplatform: facade delegates on push to validate and publish" {
	run _job "$WORKFLOW" validate
	assert_output --partial 'if: ${{ !inputs.push }}'
	assert_output --partial 'uses: ./.github/workflows/reusable-docker-multiplatform-validate.yml'
	run _job "$WORKFLOW" publish
	assert_output --partial 'if: ${{ inputs.push }}'
	assert_output --partial 'uses: ./.github/workflows/reusable-docker-multiplatform-publish.yml'
	assert_output --partial 'DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}'
	# The facade runs no build steps of its own.
	run grep -c 'docker/build-push-action@' "$WORKFLOW"
	assert_output "0"
}

@test "reusable-docker-multiplatform: facade outputs come from the publish path" {
	run grep -F 'value: ${{ jobs.publish.outputs.tags }}' "$WORKFLOW"
	assert_success
	run grep -F 'value: ${{ jobs.publish.outputs.digest }}' "$WORKFLOW"
	assert_success
}

@test "reusable-docker-multiplatform: facade forwards every input it declares to the files that read it" {
	run python3 -c '
import re, sys
def inputs(path):
    text = open(path).read()
    head = text[: text.index("    outputs:")] if "    outputs:" in text else text[: text.index("\nenv:")]
    return set(re.findall(r"^      ([a-z-]+):\n(?:        #.*\n)?        description:", head, re.M))
facade, validate, publish = (inputs(p) for p in sys.argv[1:4])
text = open(sys.argv[1]).read()
def forwarded(job):
    body = text[text.index("  " + job + ":\n"):]
    body = body[: body.index("    secrets:")] if job == "publish" else body[: body.index("\n\n")]
    return set(re.findall(r"^      ([a-z-]+): \$\{\{ inputs\.\1 \}\}$", body, re.M))
errors = []
if validate - facade or publish - facade:
    errors.append(f"callee inputs the facade lacks: {sorted((validate | publish) - facade)}")
fv, fp = forwarded("validate"), forwarded("publish")
if fv != validate:
    errors.append(f"validate forwarding differs: {sorted(fv ^ validate)}")
if fp != publish:
    errors.append(f"publish forwarding differs: {sorted(fp ^ publish)}")
if facade - validate - publish != {"push"}:
    errors.append(f"facade-only inputs other than push: {sorted(facade - validate - publish)}")
print("\n".join(errors))
sys.exit(1 if errors else 0)
' "$WORKFLOW" "$VALIDATE" "$PUBLISH"
	assert_success
}

@test "reusable-docker-multiplatform: facade uploads validate-path SARIF from its own job" {
	run _job "$WORKFLOW" upload-scan-results
	assert_output --partial 'security-events: write'
	# The runner token reads same-run artifacts: no actions: read, so the
	# facade's caller union is unchanged by the split.
	refute_line '      actions: read'
	assert_output --partial 'name: ${{ inputs.artifact-prefix }}-trivy-sarif-${{ matrix.slug }}'
	assert_output --partial 'uses: github/codeql-action/upload-sarif@'
	assert_output --partial 'category: "trivy-${{ matrix.slug }}"'
	# Gating: runs after a failed scan (always()), never without a validate
	# run, and attributes the analysis to the built source.
	assert_output --partial '      always() &&'
	assert_output --partial '!inputs.push &&'
	assert_output --partial '      inputs.scan &&'
	assert_output --partial "needs.validate.result != 'skipped'"
	assert_output --partial "ref: \${{ inputs.source-ref != '' && inputs.source-ref || github.sha }}"
}

@test "reusable-docker-multiplatform: a lost SARIF fails the upload job unless validate was cancelled" {
	run _job "$WORKFLOW" upload-scan-results
	# One delayed retry; the retry fails the job unless validate was cancelled.
	run awk '/name: Retry Trivy SARIF artifact/ { on = 1 } on && /continue-on-error:/ { print; exit }' "$WORKFLOW"
	assert_output --partial "continue-on-error: \${{ needs.validate.result == 'cancelled' }}"
	run _job "$WORKFLOW" upload-scan-results
	assert_output --partial "if: steps.fetch.outcome == 'success' || steps.retry.outcome == 'success'"
	assert_output --partial "if: steps.locate.outputs.found == 'true'"
	refute_output --partial "needs.validate.result != 'cancelled'"
}

@test "reusable-docker-multiplatform: artifact-prefix reaches the validate file from both entry points" {
	run grep -c '      artifact-prefix: ${{ inputs.artifact-prefix }}' "$WORKFLOW"
	assert_output "1"
	run grep -c '      artifact-prefix: ${{ inputs.artifact-prefix }}' \
		"${PROJECT_ROOT}/.github/workflows/reusable-docker.yml"
	assert_output "1"
	run grep -F 'run: bash .lgtm-ci-tooling/scripts/ci/actions/validate-artifact-prefix.sh' "$VALIDATE"
	assert_success
}

# ---------------------------------------------------------------- validate

@test "reusable-docker-multiplatform-validate: read-only union, no push input, no registry login" {
	run python3 "$UNION" --union reusable-docker-multiplatform-validate.yml
	assert_success
	assert_output "contents: read"
	run grep -E '^      (push|tags|provenance|sbom|cosign-sign):$' "$VALIDATE"
	assert_failure
	run grep -E 'inputs\.push|docker-auth$|secrets\.' "$VALIDATE"
	assert_failure
}

@test "reusable-docker-multiplatform-validate: builds without pushing and loads only when needed" {
	run _job "$VALIDATE" build-per-platform
	assert_output --partial '          push: false'
	assert_output --partial "\${{ inputs.health-check-cmd != '' || inputs.validate-on-pr || inputs.scan }}"
	assert_output --partial "format('{0}/{1}:validate-{2}', inputs.registry"
	assert_output --partial '          sbom: false'
	refute_output --partial 'type=registry,ref={0}-{1},mode=max'
}

@test "reusable-docker-multiplatform-validate: Trivy SARIF leaves as an artifact, not a code-scanning upload" {
	run grep -F 'upload-sarif' "$VALIDATE"
	assert_failure
	run _job "$VALIDATE" build-per-platform
	assert_output --partial 'name: ${{ inputs.artifact-prefix }}-trivy-sarif-${{ matrix.slug }}'
	# Every scanned leg uploads an artifact (SARIF or a no-sarif marker).
	assert_output --partial 'MODE: stage'
	assert_output --partial 'if-no-files-found: error'
}

@test "reusable-docker-multiplatform-validate: summary needs only the build job" {
	run _job "$VALIDATE" summary-validate
	assert_output --partial '    needs: build-per-platform'
	assert_output --partial 'inputs.validate-on-pr'
	run grep -E '^  (verify-per-platform|health-check-per-platform|merge|scan):$' "$VALIDATE"
	assert_failure
}

# ---------------------------------------------------------------- publish

@test "reusable-docker-multiplatform-publish: per-platform jobs use static display names" {
	run grep -F 'name: Docker build per platform' "$PUBLISH"
	assert_success
	run grep -F 'name: Docker build per platform' "$VALIDATE"
	assert_success
	run grep -F 'name: Docker verify per platform' "$PUBLISH"
	assert_success
	run grep -F 'name: Docker health check per platform' "$PUBLISH"
	assert_success
}

@test "reusable-docker-multiplatform-publish: preserves the build-<run_id>-<slug> staging tag scheme" {
	# The per-platform staging tags are the merged index's child manifests and
	# a separate pruner depends on this exact naming — do not change it.
	# yamllint disable-line rule:line-length
	run grep -F "format('{0}/{1}:build-{2}-{3}', inputs.registry, inputs.image-name || github.repository, github.run_id, matrix.slug)" "$PUBLISH"
	assert_success
}

@test "reusable-docker-multiplatform: both build files pass the target input to build-push-action" {
	local f
	for f in "$VALIDATE" "$PUBLISH"; do
		run grep -cE '^[[:space:]]+target: \$\{\{ inputs\.target \}\}$' "$f"
		assert_success
		assert_output "1"
	done
}

@test "reusable-docker-multiplatform-publish: every push attaches an SBOM and provenance (#963)" {
	run _job "$PUBLISH" build-per-platform
	assert_output --partial '          push: true'
	assert_output --partial '          sbom: true'
	assert_output --partial '          load: false'
	assert_output --partial 'STEP: enforce-evidence'
	# The merge attestation runs on every publish: no if: guard on it.
	run awk '
		/^  merge:$/ { in_job = 1 }
		in_job && /name: Generate artifact attestation/ { in_step = 1; found = 1; next }
		in_step && /^        if:/ { bad = 1; exit }
		in_step && /^      - name:/ { in_step = 0 }
		END { exit (bad || !found) }
	' "$PUBLISH"
	assert_success
}

@test "reusable-docker-multiplatform-publish: no validate-path or push input remains" {
	run grep -E '^      (push|validate-on-pr):$|inputs\.push|inputs\.validate-on-pr|upload-sarif@.*\n.*validate' "$PUBLISH"
	assert_failure
	run grep -F ':validate-' "$PUBLISH"
	assert_failure
}

@test "reusable-docker-multiplatform-publish: merge job gates on health-check-per-platform success" {
	run grep -F 'needs.health-check-per-platform.result ==' "$PUBLISH"
	assert_success
}

@test "reusable-docker-multiplatform-publish: health-check-per-platform waits for verify-per-platform" {
	run awk '
		/name: Docker health check per platform/ { in_job = 1 }
		in_job && /needs: \[build-per-platform, verify-per-platform\]/ { found = 1; exit }
		END { exit !found }
	' "$PUBLISH"
	assert_success
}

@test "reusable-docker-multiplatform-publish: merge-manifests runs a non-skippable verify-published gate" {
	# The published index must be pulled back from the registry and verified;
	# a dangling index (children 404) must fail the release, not publish green.
	run grep -F 'STEP: verify-published' "$PUBLISH"
	assert_success
	run awk '
		/^  merge:/ { in_job = 1 }
		in_job && /^  [a-z].*:$/ && $0 !~ /^  merge:/ { in_job = 0 }
		in_job && /name: Verify published manifest/ { in_step = 1; found = 1; next }
		in_step && /^        if:/ { bad = 1; exit }
		in_step && /^      - name:/ { in_step = 0 }
		END { exit (bad || !found) }
	' "$PUBLISH"
	assert_success
}

@test "reusable-docker-multiplatform: no file deletes staging manifests (they are index children)" {
	local f
	for f in "$WORKFLOW" "$VALIDATE" "$PUBLISH"; do
		run grep -F 'STEP: cleanup-staging' "$f"
		assert_failure
		run grep -F 'Delete staging manifests' "$f"
		assert_failure
	done
}

@test "reusable-docker-multiplatform-publish: staging digest artifacts flow between jobs" {
	run grep -cF 'name: staging-digest-${{ matrix.slug }}' "$PUBLISH"
	assert_success
	# One upload (build-per-platform) + two downloads (verify, health-check).
	assert_output "3"
}

@test "reusable-docker-multiplatform-publish: scan job scans the merged digest" {
	run grep -F 'needs.merge.outputs.digest }}' "$PUBLISH"
	assert_success
}

@test "reusable-docker-multiplatform-publish: scan job authenticates before Trivy pull" {
	run awk '
		/^  scan:/ { in_job = 1 }
		in_job && /^  [a-z]/ { if (!/^  scan:/) in_job = 0 }
		in_job && /sparse-checkout-extra:/ { saw_extra = 1 }
		in_job && /scripts\/ci\// { saw_scripts = 1 }
		in_job && /\.github\/actions\/docker-auth/ { saw_sparse = 1 }
		in_job && /name: Docker registry auth/ { saw_auth = 1 }
		in_job && /uses: \.\/\.lgtm-ci-tooling\/\.github\/actions\/docker-auth/ { saw_uses = 1 }
		in_job && /packages: read/ { saw_packages = 1 }
		END { exit !(saw_extra && saw_scripts && saw_sparse && saw_auth && saw_uses && saw_packages) }
	' "$PUBLISH"
	assert_success
}

@test "reusable-docker-multiplatform-publish: registry logins use the docker-auth composite" {
	run grep -cF 'uses: ./.lgtm-ci-tooling/.github/actions/docker-auth' "$PUBLISH"
	assert_success
	# build-per-platform, verify-per-platform, health-check-per-platform, merge, scan.
	assert_output "5"
}

@test "reusable-docker-multiplatform: free-disk-space and resource-monitor run on both build jobs" {
	local f
	for f in "$VALIDATE" "$PUBLISH"; do
		run awk '
			/^  build-per-platform:/ { in_job = 1 }
			in_job && /^  [a-z].*:$/ && $0 !~ /^  build-per-platform:/ { in_job = 0 }
			in_job && /name: Checkout and harden/ { cah = NR }
			in_job && /name: Free disk space/ { free = NR }
			in_job && /name: Start resource monitor/ { start = NR }
			in_job && /uses: docker\/build-push-action@/ { build = NR }
			in_job && /name: Dump resource monitor/ { dump = NR }
			in_job && /if: inputs\.free-disk-space && runner\.environment == .github-hosted./ {
				free_if = 1
			}
			in_job && /if: inputs\.resource-monitor/ && $0 !~ /always/ { start_if = 1 }
			in_job && /if: always\(\) && inputs\.resource-monitor/ { dump_if = 1 }
			in_job && /name: Start resource monitor/ { in_start = 1 }
			in_start && /continue-on-error: true/ { start_coe = 1 }
			in_start && /^      - name: / && $0 !~ /Start resource monitor/ { in_start = 0 }
			in_job && /scripts\/ci\/docker\/free-disk-space\.sh/ { free_script = 1 }
			in_job && /scripts\/ci\/actions\/resource-monitor\.sh start/ { start_script = 1 }
			in_job && /scripts\/ci\/actions\/resource-monitor\.sh dump/ { dump_script = 1 }
			END {
				exit !(cah && free && start && build && dump &&
					cah < free && free < start && start < build && build < dump &&
					free_if && start_if && dump_if && start_coe &&
					free_script && start_script && dump_script)
			}
		' "$f"
		assert_success
	done
}

@test "reusable-docker-multiplatform: the two build jobs share every step outside the push/validate boundary" {
	# Drift guard: the validate and publish build jobs were split from one job
	# (#1081). Steps that do not depend on push must stay identical.
	run python3 -c '
import re, sys
def steps(path):
    text = open(path).read()
    job = text[text.index("  build-per-platform:\n"):]
    job = job[: re.search(r"^  (?!build-per-platform:)[a-z][a-z0-9-]*:$|^  # ", job[3:], re.M).start() + 3]
    parts = re.split(r"^(?=      - name: )", job, flags=re.M)[1:]
    return {p.splitlines()[0]: p for p in parts}
v, p = steps(sys.argv[1]), steps(sys.argv[2])
shared = ["Harden runner", "Fail on unknown egress-preset", "Checkout repository",
          # "Checkout and harden" differs on purpose: only publish checks out the
          # docker-auth composite it logs in with.
          "Checkout lgtm-ci tooling", "Free disk space",
          "Start resource monitor", "Setup QEMU", "Setup Docker Buildx",
          "Extract metadata", "Summarize blocked egress", "Dump resource monitor"]
bad = [n for n in shared if v.get("      - name: " + n) != p.get("      - name: " + n)]
print(bad)
sys.exit(1 if bad else 0)
' "$VALIDATE" "$PUBLISH"
	assert_success
	assert_output "[]"
}
