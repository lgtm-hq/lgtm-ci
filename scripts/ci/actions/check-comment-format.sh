#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Fail reusable-publish-test-summary.yml on an unknown comment-format
#          (#1678) before any artifact is downloaded, whichever body the job
#          then posts (generated, prebuilt file or rich coverage table).
#          generate-test-summary.sh and post-pr-comment.sh refuse it again.
#
# Environment:
#   COMMENT_FORMAT  the comment-format input: classic (also when empty),
#                   compact or table
# Exits 1 on any other value, 0 otherwise. The value is never printed.

set -euo pipefail

case "${COMMENT_FORMAT:-classic}" in
classic | compact | table) exit 0 ;;
esac
echo "::error title=unknown comment-format::comment-format must be classic, compact or table"
exit 1
