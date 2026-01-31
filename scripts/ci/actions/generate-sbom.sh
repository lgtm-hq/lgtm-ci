#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Generate SBOM (Software Bill of Materials) using Syft
#
# Required environment variables:
#   STEP - Which step to run: install, generate, summary
#   TARGET - Target to scan (directory, image, file)
#   TARGET_TYPE - Type of target (dir, image, file)
#   FORMAT - SBOM output format (cyclonedx-json, spdx-json)
#   OUTPUT_FILE - Output file path

set -euo pipefail

: "${STEP:?STEP is required}"

# Source common action libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/actions.sh
source "$SCRIPT_DIR/../lib/actions.sh"

case "$STEP" in
install)
	install_anchore_tool "syft" "${SYFT_VERSION:-latest}"
	;;

generate)
	: "${TARGET:?TARGET is required}"
	: "${TARGET_TYPE:=dir}"
	: "${FORMAT:=cyclonedx-json}"
	: "${OUTPUT_FILE:=}"

	# Validate format
	if ! validate_sbom_format "$FORMAT"; then
		log_error "Unsupported SBOM format: $FORMAT"
		log_error "Supported formats: cyclonedx-json, spdx-json, cyclonedx-xml, spdx-tag-value, syft-json"
		exit 1
	fi

	# Determine output file if not specified
	if [[ -z "$OUTPUT_FILE" ]]; then
		extension=$(get_sbom_extension "$FORMAT")
		OUTPUT_FILE="sbom${extension}"
	fi

	# Resolve target for syft
	if ! SYFT_TARGET=$(resolve_scan_target "$TARGET" "$TARGET_TYPE"); then
		log_error "Unsupported target type: $TARGET_TYPE"
		exit 1
	fi

	log_info "Generating SBOM for: $SYFT_TARGET"
	log_info "Format: $FORMAT"
	log_info "Output: $OUTPUT_FILE"

	# Generate SBOM
	syft "$SYFT_TARGET" -o "$FORMAT=$OUTPUT_FILE"

	if [[ -f "$OUTPUT_FILE" ]]; then
		log_success "SBOM generated: $OUTPUT_FILE"
		log_info "Size: $(wc -c <"$OUTPUT_FILE" | tr -d ' ') bytes"

		# Count components if jq is available and format is JSON
		if command -v jq >/dev/null 2>&1 && [[ "$FORMAT" == *json* ]]; then
			component_count=$(jq -r '.components | length // 0' "$OUTPUT_FILE" 2>/dev/null || echo "unknown")
			log_info "Components: $component_count"
		fi
	else
		log_error "Failed to generate SBOM"
		exit 1
	fi

	# Set outputs
	set_github_output "sbom-file" "$OUTPUT_FILE"
	set_github_output "sbom-format" "$FORMAT"
	;;

summary)
	: "${SBOM_FILE:=$OUTPUT_FILE}"
	: "${FORMAT:=cyclonedx-json}"

	if [[ ! -f "$SBOM_FILE" ]]; then
		log_warn "SBOM file not found: $SBOM_FILE"
		exit 0
	fi

	add_github_summary "## SBOM Generation Summary"
	add_github_summary ""
	add_github_summary "| Property | Value |"
	add_github_summary "|----------|-------|"
	add_github_summary "| **Format** | \`$FORMAT\` |"
	add_github_summary "| **File** | \`$SBOM_FILE\` |"
	add_github_summary "| **Size** | $(wc -c <"$SBOM_FILE" | tr -d ' ') bytes |"

	# Extract details if jq available and JSON format
	if command -v jq >/dev/null 2>&1 && [[ "$FORMAT" == *json* ]]; then
		# CycloneDX format
		if jq -e '.bomFormat' "$SBOM_FILE" >/dev/null 2>&1; then
			spec_version=$(jq -r '.specVersion // "unknown"' "$SBOM_FILE")
			component_count=$(jq -r '.components | length // 0' "$SBOM_FILE")
			add_github_summary "| **Spec Version** | $spec_version |"
			add_github_summary "| **Components** | $component_count |"
		# SPDX format
		elif jq -e '.spdxVersion' "$SBOM_FILE" >/dev/null 2>&1; then
			spec_version=$(jq -r '.spdxVersion // "unknown"' "$SBOM_FILE")
			package_count=$(jq -r '.packages | length // 0' "$SBOM_FILE")
			add_github_summary "| **Spec Version** | $spec_version |"
			add_github_summary "| **Packages** | $package_count |"
		fi
	fi

	add_github_summary ""
	add_github_summary "> SBOM generated using [Syft](https://github.com/anchore/syft)"
	;;

*)
	die_unknown_step "$STEP"
	;;
esac
