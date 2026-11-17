#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Purpose: Run a script with only one of sha256sum and shasum on PATH (#1622)
#
# sha256_only_path <tool> <dir>
#   Fills <dir> with links to every command on the current PATH except
#   sha256sum and shasum, then adds a <tool> wrapper (sha256sum or shasum)
#   that appends its name to <dir>/calls and forwards to whichever real tool
#   exists. Use the result as the whole PATH: the other tool is absent.

sha256_only_path() {
	local tool="$1" dir="$2" path_dir entry name real_sha256sum real_shasum
	real_sha256sum="$(command -v sha256sum || true)"
	real_shasum="$(command -v shasum || true)"
	mkdir -p "$dir"
	local IFS=:
	for path_dir in $PATH; do
		[[ -d "$path_dir" ]] || continue
		for entry in "$path_dir"/*; do
			name="${entry##*/}"
			[[ -x "$entry" && ! -d "$entry" ]] || continue
			[[ "$name" == sha256sum || "$name" == shasum ]] && continue
			[[ -e "${dir}/${name}" ]] || ln -s "$entry" "${dir}/${name}"
		done
	done
	unset IFS
	{
		printf '#!/usr/bin/env bash\n'
		printf 'echo %s >>%q\n' "$tool" "${dir}/calls"
		if [[ "$tool" == sha256sum ]]; then
			if [[ -n "$real_sha256sum" ]]; then
				printf 'exec %q "$@"\n' "$real_sha256sum"
			else
				printf 'exec %q -a 256 "$@"\n' "$real_shasum"
			fi
		elif [[ -n "$real_shasum" ]]; then
			printf 'exec %q "$@"\n' "$real_shasum"
		else
			# Drop "-a 256": sha256sum takes the rest as is. The $1 belongs
			# to the wrapper, so it stays unexpanded here.
			# shellcheck disable=SC2016
			printf '[[ "$1" == -a ]] && shift 2\n'
			printf 'exec %q "$@"\n' "$real_sha256sum"
		fi
	} >"${dir}/${tool}"
	chmod +x "${dir}/${tool}"
}
