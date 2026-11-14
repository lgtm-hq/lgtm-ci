# SPDX-License-Identifier: MIT
# Purpose: Rewrite a path gem's own version in Gemfile.lock (used by ruby.sh)
#
# Usage: awk -v gem=<name> -v new_version=<version> [-v gem_dir=<dir>] \
#            -f rewrite-gemfile-lock.awk Gemfile.lock >Gemfile.lock.new
#
# gem_dir is the gem's own directory relative to Gemfile.lock (default "."),
# which is what Bundler writes as the PATH `remote:` for `gemspec` or
# `gemspec path: "<dir>"`.
#
# Rewrites only:
#   - the gem's spec lines (`    name (version[-platform])`) under the PATH
#     section whose remote is the gem's own directory (`remote: .` for a gem
#     at the lock's root, `remote: gems/demo` for one in gems/demo);
#   - the matching CHECKSUMS lines that carry no checksum, which is how
#     Bundler records a path gem.
# A same-name spec under GEM or GIT is a published copy and is left alone,
# as is DEPENDENCIES (`name!` for a path gem). A platform suffix is kept.
#
# Version syntax follows Bundler's lockfile grammar: the version runs to the
# first '-', and must be RubyGems syntax (segments of [0-9A-Za-z]+ joined by
# '.'); the rest is the platform.
#
# Exit status: 0 rewritten; 2 no project PATH spec for the gem; 3 the gem is
# locked only from GEM, GIT or another PATH (stderr: "only in: ..."); 4 a
# project spec version is not RubyGems syntax (stderr: "invalid version: ...").

# Split "<indent>name (inner)" into the globals name, ver and plat.
# Returns 0 when the line is not a spec line at exactly that indentation.
function parse_spec(line, indent, body, open, inner, dash) {
	if (substr(line, 1, length(indent)) != indent) return 0
	body = substr(line, length(indent) + 1)
	if (body ~ /^ / || body !~ /^[^ (]+ \([^()]*\)$/) return 0
	open = index(body, " (")
	name = substr(body, 1, open - 1)
	inner = substr(body, open + 2, length(body) - open - 2)
	dash = index(inner, "-")
	if (dash > 0) {
		ver = substr(inner, 1, dash - 1)
		plat = substr(inner, dash)
	} else {
		ver = inner
		plat = ""
	}
	return 1
}

# Drop a leading "./" and trailing "/"s; an empty result is ".".
function norm_dir(r) {
	sub(/^\.\//, "", r)
	while (r ~ /.\/$/) sub(/\/$/, "", r)
	if (r == "") r = "."
	return r
}

function is_project_remote(r) {
	return norm_dir(r) == own_dir
}

BEGIN {
	ver_re = "^[0-9A-Za-z]+(\\.[0-9A-Za-z]+)*$"
	own_dir = norm_dir(gem_dir)
}

# Top-level section headers start in column 1.
/^[^ ]/ {
	section = $0
	remote = ""
	in_specs = 0
}

section == "PATH" && /^  remote: / { remote = substr($0, 11) }

/^  specs:$/ { in_specs = 1 }

section == "PATH" && in_specs && parse_spec($0, "    ") && name == gem {
	if (!is_project_remote(remote)) {
		elsewhere = elsewhere " PATH(" remote ")"
	} else if (ver !~ ver_re) {
		bad = bad " " ver plat
	} else {
		old[ver plat] = 1
		rewritten++
		print "    " gem " (" new_version plat ")"
		next
	}
}

(section == "GEM" || section == "GIT") && in_specs && parse_spec($0, "    ") && name == gem {
	elsewhere = elsewhere " " section
}

section == "CHECKSUMS" && parse_spec($0, "  ") && name == gem && ((ver plat) in old) {
	print "  " gem " (" new_version plat ")"
	next
}

{ print }

END {
	if (bad != "") {
		print "invalid version:" bad > "/dev/stderr"
		exit 4
	}
	if (rewritten == 0) {
		if (elsewhere != "") {
			print "only in:" elsewhere > "/dev/stderr"
			exit 3
		}
		exit 2
	}
}
