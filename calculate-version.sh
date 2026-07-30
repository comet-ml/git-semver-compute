#!/bin/sh

# RegEx source:
# https://web.archive.org/web/20221230095605/https://semver.org/#is-there-a-suggested-regular-expression-regex-to-check-a-semver-string
SEMVER_REGEX='^(?P<major>0|[1-9]\d*)\.(?P<minor>0|[1-9]\d*)\.(?P<patch>0|[1-9]\d*)(?:-(?P<prerelease>(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+(?P<buildmetadata>[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$'

# Prefixes tolerated in front of a semantic version when scanning tags. Comma-
# separated and overridable with --tolerate-prefix; defaults to 'v' (e.g.
# v1.2.3). Matching is case-insensitive and the prefix is stripped from output.
TOLERATE_PREFIX="v"

# When --oci is given, the '+' build-metadata separator (which OCI image tags
# disallow) is replaced in the output. OCI_PLUS is the replacement string,
# defaulting to '_' and overridable via --oci=SEP (e.g. --oci=--).
OCI_MODE=0
OCI_PLUS="_"

# When --preserve-metadata is given, build metadata ('+...') on the nearest tag
# is carried onto `next` output instead of being stripped. Only affects `next`.
PRESERVE_METADATA=0

# When --add-metadata=META is given, META is appended to the output's build
# metadata in any mode (starting a '+' section if there is none). Empty means
# nothing to add.
ADD_METADATA=""

###############
### Helpers ###
###############

# Like bare `printf ""` but format characters are not unintentionally parsed.
print() {
	printf '%s' "$1"
}

println() {
	print "$1"
	printf "\n"
}

println_err() {
	println "$1" >&2
}

usage() {
	println "Usage: $(basename "$0") [--tolerate-prefix=LIST] [--oci[=SEP]] [--preserve-metadata] [--add-metadata=META] [next major|minor|patch|prerelease [bump] [label] | base]"
}

usage_err() {
	usage >&2
}

# Fatal error for argument problems: prints the message, the usage, and exits.
die_usage() {
	println_err "Error: $1"
	usage_err
	exit 1
}

# Fatal error for computation problems: prints the message and exits (no usage).
die() {
	println_err "Error: $1"
	exit 1
}


###########################
### Pure String Helpers ###
###########################

# Echo the longest tolerated prefix that a given string (tag name) starts with
# (matched case-insensitively), preserving the tag's original casing, or
# nothing if none matches.
# The tolerated prefixes come from the comma-separated TOLERATE_PREFIX list.
tolerated_prefix() {
	local tag=$1
	local best=""
	local prefix_list=$TOLERATE_PREFIX
	local tag_lower=$(printf '%s' "$tag" | tr '[:upper:]' '[:lower:]')
	local prefix prefix_lower

	while [ -n "$prefix_list" ]
	do
		# Pop the next prefix from the comma-separated prefix_list.
		case "$prefix_list" in
			*,*)
				prefix=${prefix_list%%,*}
				prefix_list=${prefix_list#*,}
				;;
			*)
				prefix=$prefix_list;
				prefix_list=""
				;;
		esac
		# Trim surrounding whitespace.
		prefix=${prefix#"${prefix%%[![:space:]]*}"}
		prefix=${prefix%"${prefix##*[![:space:]]}"}
		# Handle the case where a list had an element of only whitespace. Discard.
		if [ -z "$prefix" ]
		then
			continue
		fi
		# Only a longer prefix than the current best can win.
		if [ ${#prefix} -le ${#best} ]
		then
			continue
		fi
		# Compare case-insensitively; keep the tag's original casing on a match.
		prefix_lower=$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]')
		# Use case statement for easy globbing.
		case "$tag_lower" in
			"$prefix_lower"*)
				best=$(print "$tag" | cut -c "1-${#prefix}")
				;;
		esac
	done
	print "$best"
}

# Echo the tag with any tolerated prefix stripped.
strip_prefix() {
	local prefix
	prefix=$(tolerated_prefix "$1")
	print "${1#"$prefix"}"
}

# Return success if the given tag is a valid semantic version once any tolerated
# prefix is removed. Uses the official SemVer regex via perl.
is_semver() {
	println "$(strip_prefix "$1")" | perl -ne "/$SEMVER_REGEX/ && (\$found=1); END {exit !\$found}"
}

# Echo the input with every '+' replaced by OCI_PLUS, for OCI-tag-compatible
# output (OCI image tags disallow '+').
oci_encode() {
	local in=$1
	local out=""

	while [ "$in" != "${in#*+}" ]
	do
		out="$out${in%%+*}$OCI_PLUS"
		in=${in#*+}
	done
	print "$out$in"
}

# Echo $1 with build metadata $2 attached: start a '+' section if there is none,
# otherwise append with '-' (the same separator convention as the build-version
# metadata). Uses '+' regardless of --oci; the OCI pass runs afterward.
inject_metadata() {
	case "$1" in
		*+*) print "$1-$2" ;;
		*)   print "$1+$2" ;;
	esac
}

# Echo the SHA-1 of stdin, using whichever digest tool is available (GNU
# coreutils, BSD/macOS, or OpenSSL).
sha1() {
	if command -v sha1sum >/dev/null 2>&1
	then
		sha1sum | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1
	then
		shasum -a 1 | awk '{print $1}'
	else
		openssl sha1 | awk '{print $NF}'
	fi
}

# Echo the numeric core bumped by the given level, dropping any pre-release.
bump_core_version() {
	# When bumpting each component, the smaller components go to zero.
	case "$1" in
		major)
			println "$((MAJOR + 1)).0.0"
			;;
		minor)
			println "$MAJOR.$((MINOR + 1)).0"
			;;
		patch)
			println "$MAJOR.$MINOR.$((PATCH + 1))"
			;;
	esac
}

# Downgrade guard for pre-release label switches: plain (empty label) sorts
# lowest, per SemVer's "numeric identifiers have lower precedence"; labels
# compare in ASCII order (SemVer precedence). Returns 0 (true) if $1 is a
# downgrade from $2.
is_prerelease_downgrade() {
	local new=$1
	local cur=$2
	if [ -z "$new" ] && [ -n "$cur" ]
	then
		return 0  # true
	fi
	if [ -n "$new" ] && [ -z "$cur" ]
	then
		return 1  # false
	fi
	if [ "$new" = "$cur" ]
	then
		return 1  # false
	fi
	# Use perl to compare labels in ASCII order.
	perl -e 'exit(($ARGV[0] cmp $ARGV[1]) >= 0)' -- "$new" "$cur"
}

########################
### Argument Parsing ###
########################

# Parse the command line, setting MODE / BUMP / LABEL and, if the
# --tolerate-prefix option is present, TOLERATE_PREFIX.
# Usage:
#   calculate-version.sh                                Current build version.
#   calculate-version.sh base                           Nearest semver tag.
#   calculate-version.sh next major|minor|patch         Next release version.
#   calculate-version.sh next prerelease [bump] [label] Next pre-release version.
# The --tolerate-prefix=LIST option may appear anywhere and overrides the set of
# prefixes tolerated in front of a semver tag (default 'v').
parse_args() {
	MODE=""
	BUMP=""
	LABEL=""

	# Pull non-positional option arguments wherever they appear, leaving only the
	# positional args in "$@".
	# A sentinel marks the end of the original list as positionals are rotated
	# to the back.
	local sentinel="__end_$$__"
	set -- "$@" "$sentinel"
	while [ "$1" != "$sentinel" ]
	do
		case "$1" in
			--tolerate-prefix=*)
				TOLERATE_PREFIX=${1#--tolerate-prefix=}
				shift
				;;
			--tolerate-prefix)
				shift  # Grab the next arg
				if [ "$1" = "$sentinel" ]
				then
					die_usage "--tolerate-prefix requires a value."
				fi
				TOLERATE_PREFIX=$1
				shift
				;;
			--oci)
				# --oci without an = cannot take a param.
				OCI_MODE=1
				shift
				;;
			--oci=*)
				OCI_MODE=1
				OCI_PLUS=${1#--oci=}
				shift
				;;
			--preserve-metadata)
				PRESERVE_METADATA=1
				shift
				;;
			--add-metadata=*)
				ADD_METADATA=${1#--add-metadata=}
				shift
				;;
			--add-metadata)
				shift  # Grab the next arg
				if [ "$1" = "$sentinel" ]
				then
					die_usage "--add-metadata requires a value."
				fi
				ADD_METADATA=$1
				shift
				;;
			*)
				# Found something that is not a known non-positional arg.
				# Rotate it to the end of the args (after the sentinel).
				set -- "$@" "$1"
				shift
				;;
		esac
	done
	shift   # drop the sentinel

	# Dispatch on the positional subcommand.
	case "$1" in
		### No subcommand ###
		# calculate current build version
		"")
			MODE=""
			;;
		### Base ###
		# Return the nearest semver tag
		base)
			MODE="base"
			if [ -n "$2" ]
			then
				die_usage "'base' takes no extra arguments."
			fi
			;;
		### Next ###
		# Calculate the next release version
		next)
			MODE=$2
			case "$MODE" in
				major|minor|patch)
					if [ -n "$3" ]
					then
						die_usage "'$MODE' takes no extra arguments."
					fi
					;;
				prerelease)
					# The optional positional args are [bump] and [label] in
					# either order: a token matching a reserved bump keyword is
					# the bump, anything else is the label.
					shift 2
					for arg in "$@"
					do
						# Ignore empty string args ("  ")
						if [ -z "$arg" ]
						then
							continue
						fi
						case "$arg" in
							# If a valid bump keyword is provided, the prerelease will
							# be made on that.
							major|minor|patch)
								if [ -n "$BUMP" ]
								then
									die_usage "bump specified more than once."
								fi
								BUMP=$arg
								;;
							# If no valid bump keyword is provided, treat is as the label.
							*)
								if [ -n "$LABEL" ]
								then
									die_usage "unexpected argument '$arg'."
								fi
								LABEL=$arg
								;;
						esac
					done
					;;
				# Next without a mode
				"")
					die_usage "'next' requires a mode (major|minor|patch|prerelease)."
					;;
				# Unknown mode
				*)
					die_usage "unknown mode '$MODE'."
					;;
			esac
			;;
		### Invalid Argument ###
		# Unknown subcommand found
		*)
			die_usage "unknown argument '$1'."
			;;
	esac
}

######################
### Tag Resolution ###
######################

# Resolve the most recent valid semantic-version tag into TAG, rewinding
# through history past any non-semver tags.
# Falls back to 0.0.0 when none is found.
resolve_tag() {
	# Describe tag does something very similar to what we want already.
	# However it doesn't discrimate between semver compatible tags and not.
	# Here we use --abbrev=0 to strip the commit distance (-1-gffff), so we're
	# grabbing the nearest tag of any type first.
	TAG=$(git describe --tags --abbrev=0 2>/dev/null)

	# If there are no tags, use 0.0.0
	if [ -z "$TAG" ]
	then
		TAG=0.0.0
	fi

	# If the most recent tag is not a valid semantic version, rewind until we
	# find one.
	while ! is_semver "$TAG"
	do
		local tag_hash
		local previous_tag_hash

		# Get the hash for the most recent tag.
		tag_hash=$(git rev-list -n 1 "$TAG")

		# Get the hash for the commit before the latest tag.
		previous_tag_hash=$(git rev-list "$tag_hash" | sed '2q;d')

		# Rewind commits to the previous tag commit.
		while git describe --tags "$previous_tag_hash" 2>/dev/null \
			| perl -ne \
				'/.+?-\d+-g[[:xdigit:]]{7}$/ && ($found=1); END {exit !$found}'
		do
			tag_hash=$previous_tag_hash
			previous_tag_hash=$(git rev-list "$tag_hash" | sed '2q;d')
			# If we've reached the beginning of the commit history, break out of
			# the loop. This should never happen.
			if [ -z "$previous_tag_hash" ]
			then
				break
			fi
		done
		# Get the tag, or return 0.0.0 if there are no tags or if we've reached
		# the end of the commit history.
		TAG=$(git describe --tags "$previous_tag_hash" --abbrev=0 2>/dev/null || printf '%s\n' 0.0.0)
	done
}


#######################
### Version parsing ###
#######################

# Parse a prefix-stripped version into MAJOR / MINOR / PATCH / PRE_BODY and,
# if a pre-release is present, CUR_LABEL / CUR_COUNTER.
parse_version() {
	local counter
	local parsed
	local build_meta

	# Decompose with the canonical SemVer regex — the same definition used to
	# validate the tag — so extraction cannot disagree with validation. The
	# named capture groups yield major/minor/patch/prerelease/buildmetadata,
	# joined with '|'; the optional groups come back empty.
	parsed=$(print "$1" | SEMVER_REGEX="$SEMVER_REGEX" perl -ne '
		if (/$ENV{SEMVER_REGEX}/) {
			print join("|", map { defined $_ ? $_ : "" }
				@+{qw(major minor patch prerelease buildmetadata)});
		}')
	if [ -z "$parsed" ]
	then
		die "base tag '$TAG' is not a parseable semantic version."
	fi
	IFS='|' read -r MAJOR MINOR PATCH PRE_BODY build_meta <<-EOF
	$parsed
	EOF

	# Build metadata is captured in META so --preserve-metadata can re-attach it.
	META=${build_meta:+"+$build_meta"}

	# Split an existing pre-release body into label + counter (concatenated form,
	# e.g. 'alpha0'; a dotted 'alpha.0' is tolerated on input). Stripping the
	# longest prefix ending in a non-digit leaves the trailing run of digits.
	CUR_LABEL=""
	CUR_COUNTER=0
	if [ -n "$PRE_BODY" ]
	then
		counter=${PRE_BODY##*[!0-9]}
		case "$counter" in
			"")
				# No trailing counter (e.g. '-alpha'): whole body is the label.
				CUR_LABEL=$PRE_BODY
				CUR_COUNTER=0
				;;
			*)
				CUR_COUNTER=$counter
				CUR_LABEL=${PRE_BODY%"$counter"}
				CUR_LABEL=${CUR_LABEL%[-.]}   # strip any trailing separator
				;;
		esac
	fi
}


################################
### Next-version computation ###
################################

# Compute the next pre-release version into NEXT.
compute_next_prerelease() {
	if [ -n "$BUMP" ]
	then
		# Explicit bump always increments the core and drops any existing
		# pre-release, then starts the counter at 0.
		NEXT="$(bump_core_version "$BUMP")-${LABEL}0"
	elif [ -n "$PRE_BODY" ]
	then
		# No bump on an existing pre-release: increment or switch label.
		if [ -z "$LABEL" ] || [ "$LABEL" = "$CUR_LABEL" ]
		then
			NEXT="$MAJOR.$MINOR.$PATCH-$CUR_LABEL$((CUR_COUNTER + 1))"
		elif is_prerelease_downgrade "$LABEL" "$CUR_LABEL"
		then
			die "pre-release label '$LABEL' is a downgrade from '$CUR_LABEL'."
		else
			NEXT="$MAJOR.$MINOR.$PATCH-${LABEL}0"
		fi
	else
		die "'next prerelease' on a non-pre-release version requires a bump level (major|minor|patch)."
	fi
}

# Compute the next version into NEXT, based on MODE and the parsed components.
compute_next() {
	case "$MODE" in
		major|minor)
			NEXT=$(bump_core_version "$MODE")
			;;
		patch)
			if [ -n "$PRE_BODY" ]
			then
				# Finalize the in-progress pre-release: drop it, no numeric bump.
				NEXT="$MAJOR.$MINOR.$PATCH"
			else
				NEXT=$(bump_core_version patch)
			fi
			;;
		prerelease)
			compute_next_prerelease
			;;
	esac
}


#############################
### Current build version ###
#############################

# Append a metadata piece to VERSION, using '+' for the first piece and '-' for
# subsequent ones. Reads/updates the caller's VERSION and has_metadata via
# dynamic scoping.
append_metadata() {
	if [ "$has_metadata" -eq 0 ]
	then
		VERSION="$VERSION+"
		has_metadata=1
	else
		VERSION="$VERSION-"
	fi
	VERSION="$VERSION$1"
}

# Compute the current build version into VERSION by appending commit-count/hash
# and dirty-tree drift metadata to the base version.
compute_current() {
	local commits
	local short_hash
	local drift_digest
	local has_metadata

	# Get the number of commits since the last valid tag.
	if [ "$TAG" = "0.0.0" ]
	then
		commits=$(git rev-list --count --no-merges HEAD)
	else
		commits=$(git rev-list --count --no-merges "$TAG..HEAD")
	fi

	short_hash=$(git rev-parse --short HEAD)

	# If any tracked files have been modified, add a hash of the diff to the
	# version.
	drift_digest=$(git status --porcelain | perl -ne '/^\s?(M|A|D)/ && ($found=1); END {exit !$found}' && git diff HEAD | sha1)

	# Determine if the version already has metadata.
	has_metadata=$(printf '%s\n' "$VERSION" | perl -ne '/\+/ && ($found=1); END {exit !$found}' && printf '%s\n' 1 || printf '%s\n' 0)

	# Add commit count and hash to the version if there are any commits since the
	# last tag. Add the g prefix to the hash to indicate that it is a Git hash,
	# just like `git describe --tags` does.
	if [ "$commits" -gt 0 ]
	then
		append_metadata "$commits-g$short_hash"
	fi

	# Add a hash of the diff to the version if there are any tracked files that
	# have been modified.
	if [ -n "$drift_digest" ]
	then
		append_metadata "$drift_digest"
	fi
}


###################
### Entry point ###
###################

main() {
	parse_args "$@"
	resolve_tag

	# Strip any tolerated prefix from the resolved tag.
	VERSION=$(strip_prefix "$TAG")

	local output
	case "$MODE" in
		# No subcommand: the full current build version.
		"")
			compute_current
			output=$VERSION
			;;
		# Just the nearest semver tag, prefix stripped.
		base)
			output=$VERSION
			;;
		# A `next` release/pre-release version, preserving the tag's prefix.
		major|minor|patch|prerelease)
			PREFIX=$(tolerated_prefix "$TAG")
			parse_version "$VERSION"
			compute_next
			output="$PREFIX$NEXT"
			# Re-attach the tag's build metadata when asked to preserve it.
			if [ "$PRESERVE_METADATA" -eq 1 ]
			then
				output="$output$META"
			fi
			;;
		*)
			die_usage "Error: unknown mode"
			;;
	esac

	# Inject user-supplied metadata (any mode), before OCI encoding so an added
	# '+' is encoded too.
	if [ -n "$ADD_METADATA" ]
	then
		output=$(inject_metadata "$output" "$ADD_METADATA")
	fi

	# Convert '+' to an OCI-tag-compatible separator when requested.
	if [ "$OCI_MODE" -eq 1 ]
	then
		output=$(oci_encode "$output")
	fi
	print "$output"
}

main "$@"
