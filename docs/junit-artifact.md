# Counting from a JUnit report (`junit-artifact`, #1686)

A caller of `reusable-publish-test-summary.yml` that does not use an lgtm-ci test reusable can
hand the workflow its JUnit XML reports instead of three numbers. The workflow downloads the
artifact, counts every test case itself (skipped tests and expected failures included), lists the
expected failures with their reasons, and renders the usual test summary comment.

## Inputs

| Input            | Meaning                                                                                                                                     |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `junit-artifact` | Artifact name or glob of the JUnit reports in this run, for example `test-reports` or `test-reports-*`. Each matching artifact is one leg.  |
| `junit-path`     | Glob of the JUnit files inside each artifact, relative and without `..`. Empty (default) means `**/*.xml`: every `.xml` file, at any depth. |

When `junit-artifact` is set:

- `tests-passed`, `tests-failed`, `tests-total`, `tests-skipped`, `tests-xfailed` and
  `tests-xpassed` are ignored;
- `coverage-percent` (with `coverage-enabled: true`) still applies: a JUnit report carries no
  coverage;
- `results-expected-count`, when set, is the number of artifacts the glob must match;
- `job-result`, `comment-history`, `comment-fields` and the rest behave as before.

**Precedence.** `junit-artifact` and `results-artifact-pattern` are two sources of the same counts,
so setting both fails the job before anything is downloaded, with the error "junit-artifact and
results-artifact-pattern cannot both be set". `prebuilt-test-summary-file` and a successful
`rich-coverage-comment` take precedence over both, as they did over `results-artifact-pattern`.

Each matching artifact becomes one results.v1 document (`tool: junit`, `source.runner:
junit-artifact`, `matrix: {key: artifact, value: <artifact name>}`), and the documents are summed
as matrix legs are (see [workflow-contract.md](workflow-contract.md)): counts added, the
expected-failure lists joined in artifact order without repeats and cut at 50 entries, with the rest
counted as omitted. Several files inside one artifact are summed into its leg; several
`<testsuite>` elements, and `<testsuite>` elements nested in `<testsuites>`, are summed within a
file.

**Failures.** No artifact matching `junit-artifact`, or an artifact without a file matching
`junit-path`, fails the job and names the artifact. A file that cannot be read safely (below) does
not fail the job: its leg has status `error`, and the comment says the test counts are unreadable,
never that the run passed.

## Mapping

Per `<testcase>`, by its direct children:

| Child                                       | Counted as                                               |
| ------------------------------------------- | -------------------------------------------------------- |
| none (or only output, properties)           | passed                                                   |
| `<failure>` or `<error>`                    | failed (pytest writes a strict unexpected pass this way) |
| `<skipped type="pytest.xfail" message="…">` | expected failure, with `message` as its reason           |
| any other `<skipped>`                       | skipped                                                  |

A test case with several of these counts once, as the first row of this order that applies:
failed, expected failure, skipped. The test id in the expected-failure list is
`<classname>::<name>` (`<name>` alone without a `classname`), for example
`tests.test_api.TestLogin::test_expired[admin]`.

pytest writes a test that failed in its call and then errored in teardown as two `<testcase>`
elements with the same id, one directly after the other. A `<testcase>` that directly follows one
with the same non-empty id is therefore the same test, counted once with the worse outcome; the
same id further apart, or an empty id, is another test.

JUnit has no element for a non-strict unexpected pass: pytest writes it as a plain passing test
case, so it is counted as passed and the comment has no "Unexpected passes" row. Other runners map
the same way where their JUnit output uses these elements.

### Totals must agree with the test cases

Where a `<testsuite>` or `<testsuites>` element carries `tests`, `failures`, `errors` or
`skipped`, each must equal what its test cases add up to: `tests` the number of test cases
(counted per element or per id), `failures`, `errors` and `skipped` the number of those child
elements. A file whose totals disagree, or whose total is not a whole number of at most nine
digits, is unreadable. A report that carries totals without its test cases cannot be counted
from: list the test cases in it.

## Limits and untrusted XML

A JUnit report is written by the code under test, so the reader treats it as hostile. It is
`scripts/ci/lib/testing/junit_reader.py`, a standard-library script run as `python3 -I`.

| Limit                     | Value                |
| ------------------------- | -------------------- |
| One file                  | 16 MiB               |
| All files of one artifact | 64 MiB               |
| Files per artifact        | 1,000                |
| Test cases per artifact   | 50,000               |
| Element nesting           | 32 levels            |
| Test id or reason kept    | 500 characters (`…`) |

Over any limit, the leg is unreadable. The reader also refuses:

- **a DOCTYPE or entity declaration** in the prolog, checked on the text before parsing. This is
  what keeps entity expansion ("billion laughs") and external entities (a `SYSTEM` entity naming a
  file or a URL) out: without a DOCTYPE no entity can be declared, and a reference to an undeclared
  entity is a parse error. The parser is expat, the one `xml.etree.ElementTree` uses, called
  directly so that handlers can stop it the moment it sees a DOCTYPE, an entity declaration or an
  external entity reference (a second line of defence), with parameter entities off. Nothing is
  ever fetched or read besides the report;
- **anything but UTF-8**: invalid UTF-8 bytes, or an XML declaration naming another encoding;
- **a file that is not well-formed** (truncated, for example), whose root is not `<testsuite>` or
  `<testsuites>`, or that places a test case outside a `<testsuite>`;
- **a symbolic link** among the matched files.

Test ids and reasons reach the comment only through the shared sanitiser
([comment-sanitize.md](comment-sanitize.md)), as every expected-failure reason does. The reason
in the job-log warning for an unreadable file is the reader's own text, with any character outside
a small safe set replaced by `?`.

No permission or egress host is added: the artifact download uses the pinned
`actions/download-artifact` the workflow already uses for `results-artifact-pattern`, under the
same `contents: read` and `pull-requests: write`.

## Example: replacing a counting script

Before, a caller ran its tests, turned the report into numbers with its own script, and passed
those numbers on. Its script decided what got lost; here, skipped tests and expected failures:

```yaml
jobs:
  test:
    runs-on: ubuntu-26.04
    permissions:
      contents: read
    outputs:
      passed: ${{ steps.count.outputs.passed }}
      failed: ${{ steps.count.outputs.failed }}
      total: ${{ steps.count.outputs.total }}
    steps:
      # … checkout, setup …
      - run: uv run pytest --junitxml=reports/junit.xml
      - id: count
        run: bash scripts/count-junit.sh reports/junit.xml

  test-summary:
    needs: test
    if: ${{ !cancelled() && github.event_name == 'pull_request' }}
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-test-summary.yml@<sha> # vX.Y.Z
    permissions:
      contents: read
      pull-requests: write
    with:
      test-suite-name: Python Tests
      comment-marker: python-test-results
      tests-passed: ${{ needs.test.outputs.passed }}
      tests-failed: ${{ needs.test.outputs.failed }}
      tests-total: ${{ needs.test.outputs.total }}
      job-result: ${{ needs.test.result }}
```

After, the test job uploads the report and the summary counts it:

```yaml
jobs:
  test:
    runs-on: ubuntu-26.04
    permissions:
      contents: read
    steps:
      # … checkout, setup …
      - run: uv run pytest --junitxml=reports/junit.xml
      - if: ${{ !cancelled() }}
        uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
        with:
          name: test-reports
          path: reports/junit.xml
          if-no-files-found: error

  test-summary:
    needs: test
    if: ${{ !cancelled() && github.event_name == 'pull_request' }}
    uses: lgtm-hq/lgtm-ci/.github/workflows/reusable-publish-test-summary.yml@<sha> # vX.Y.Z
    permissions:
      contents: read
      pull-requests: write
    with:
      test-suite-name: Python Tests
      comment-marker: python-test-results
      junit-artifact: test-reports
      job-result: ${{ needs.test.result }}
```

A sharded or matrix test job uploads one artifact per leg (`test-reports-${{ matrix.shard }}`)
and passes `junit-artifact: test-reports-*`, with `results-expected-count` set to the number of
legs so a lost leg fails the comment job.

## The Python reusable

`reusable-test-python.yml` counts from the pytest-json-report file, which does not record the
`reason=` of `@pytest.mark.xfail`: for a marked test that raised, the reason shown is the
exception. pytest's own JUnit output does record it. `pytest_results_v1` (in
`scripts/ci/lib/testing/parse/pytest.sh`) and the parse step of `run-pytest.sh` (`JUNIT_FILE`)
take the marker reasons from a JUnit report of the same run when one is given, matching each
JSON test id to pytest's JUnit `classname` and `name`; ids and counts are unchanged. The reusable
does not write a JUnit report today, so it does not pass one yet (#1686 records why).
