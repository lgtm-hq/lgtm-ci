#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate multi-format SBOMs for release-asset mode.
#
# Required environment variables:
#   none (defaults applied)
#
# Optional environment variables:
#   TARGET       - Scan target (default: .)
#   TARGET_TYPE  - dir | image | file (default: dir)
#   FORMATS      - Comma/space/newline-separated Syft formats
#                  (default: spdx-json,cyclonedx-json)
#   OUTPUT_DIR   - Directory for generated SBOM files (default: sbom)
#   SYFT_VERSION - Syft version for install step (default: latest)
#   STEP         - install | generate | parse-formats (default: generate)
#
# parse-formats prints one canonical format per line (for tests / callers).

set -euo pipefail

: "${STEP:=generate}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

# Parse FORMATS into canonical Syft format names (one per line).
# Usage: parse_sbom_format_list "spdx-json, cyclonedx-json"
parse_sbom_format_list() {
	local raw="${1:-}"
	local token
	local -a formats=()
	local normalized

	raw="${raw//,/ }"
	raw="${raw//$'\n'/ }"

	for token in ${raw}; do
		[[ -z "${token}" ]] && continue
		normalized="$(normalize_sbom_format "${token}")"
		if ! validate_sbom_format "${normalized}"; then
			echo "::error::Unsupported SBOM format: ${token}" >&2
			return 1
		fi
		formats+=("${normalized}")
	done

	if [[ ${#formats[@]} -eq 0 ]]; then
		echo "::error::formats must list at least one SBOM format" >&2
		return 1
	fi

	printf '%s\n' "${formats[@]}"
}

# Map a format to a stable release-asset filename under OUTPUT_DIR.
sbom_release_filename() {
	local format="$1"
	local output_dir="$2"

	case "${format}" in
	spdx-json)
		echo "${output_dir}/sbom.spdx.json"
		;;
	cyclonedx-json)
		echo "${output_dir}/sbom.cyclonedx.json"
		;;
	cyclonedx-xml)
		echo "${output_dir}/sbom.cyclonedx.xml"
		;;
	spdx-tag-value)
		echo "${output_dir}/sbom.spdx"
		;;
	syft-json)
		echo "${output_dir}/sbom.syft.json"
		;;
	*)
		echo "${output_dir}/sbom$(get_sbom_extension "${format}")"
		;;
	esac
}

case "${STEP}" in
parse-formats)
	: "${FORMATS:=spdx-json,cyclonedx-json}"
	parse_sbom_format_list "${FORMATS}"
	;;

install)
	install_anchore_tool "syft" "${SYFT_VERSION:-latest}"
	;;

generate)
	: "${TARGET:=.}"
	: "${TARGET_TYPE:=dir}"
	: "${FORMATS:=spdx-json,cyclonedx-json}"
	: "${OUTPUT_DIR:=sbom}"

	mkdir -p "${OUTPUT_DIR}"

	mapfile -t format_list < <(parse_sbom_format_list "${FORMATS}")

	if ! validate_scan_target "${TARGET}" "${TARGET_TYPE}"; then
		log_error "Invalid target for type ${TARGET_TYPE}: ${TARGET}"
		exit 1
	fi

	if ! SYFT_TARGET="$(resolve_scan_target "${TARGET}" "${TARGET_TYPE}")"; then
		log_error "Unsupported target type: ${TARGET_TYPE}"
		exit 1
	fi

	generated=()
	for format in "${format_list[@]}"; do
		outfile="$(sbom_release_filename "${format}" "${OUTPUT_DIR}")"
		log_info "Generating ${format} -> ${outfile}"
		syft "${SYFT_TARGET}" -o "${format}=${outfile}"
		if [[ ! -f "${outfile}" ]]; then
			log_error "Failed to generate SBOM: ${outfile}"
			exit 1
		fi
		generated+=("${outfile}")
	done

	log_success "Generated ${#generated[@]} SBOM file(s) in ${OUTPUT_DIR}"
	set_github_output "sbom-dir" "${OUTPUT_DIR}"
	set_github_output "sbom-count" "${#generated[@]}"
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		{
			echo "sbom-files<<EOF"
			printf '%s\n' "${generated[@]}"
			echo "EOF"
		} >>"${GITHUB_OUTPUT}"
	fi
	;;

*)
	die_unknown_step "${STEP}"
	;;
esac
