#!/bin/sh

########################
### Pseudo Constants ###
########################

# RegEx source:
# https://web.archive.org/web/20221230095605/https://semver.org/#is-there-a-suggested-regular-expression-regex-to-check-a-semver-string
SEMVER_REGEX='^(?P<major>0|[1-9]\d*)\.(?P<minor>0|[1-9]\d*)\.(?P<patch>0|[1-9]\d*)(?:-(?P<prerelease>(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+(?P<buildmetadata>[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$'

###############
### Globals ###
###############

# Prefixes tolerated in front of a semantic version when scanning tags. Comma-
# separated and overridable with --tolerate-prefix; defaults to 'v' (e.g.
# v1.2.3). Matching is case-insensitive and the prefix is stripped from output.
TOLERATE_PREFIX="v"

# When --oci is used, the '+' build-metadata separator (which OCI image tags
# disallow) is replaced in the output. OCI_PLUS is the replacement string,
# defaulting to '_' and overridable via --oci=SEP (e.g. --oci=--).
OCI_MODE=0
OCI_PLUS="_"

# When --preserve-metadata is used, build metadata ('+...') on the nearest tag
# is carried onto `next` output instead of being stripped. Only affects `next`.
PRESERVE_METADATA=0

# When --add-metadata=META is used, META is appended to the output's build
# metadata in any mode (starting a '+' section if there is none). Empty means
# nothing to add.
ADD_METADATA=""

# When --full-tags is used, the `history` subcommand prints raw tag names
# (prefix and metadata intact) instead of prefix-stripped versions.
FULL_TAGS=0

# When --sort is used, the `history` subcommand orders its output by semantic
# version (highest first) instead of git topological order. Build metadata is
# ignored for ordering.
# (https://web.archive.org/web/20221230095605/https://semver.org/#spec-item-10)
# Tags with equal precedence keep their encounter order.
SORT=0

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
	println "Usage: $(basename "$0") [--tolerate-prefix=LIST] [--oci[=SEP]] [--preserve-metadata] [--add-metadata=META] [next major|minor|patch|prerelease [bump] [label] | base | history [--full-tags] [--sort]]"
}

# Print the usage line plus a detailed description of the subcommands and options.
help() {
	usage
	cat <<-HERE

	Compute a Semantic Version compliant version from git tags and commits.
	With no subcommand it prints the current build version: the nearest semver
	tag plus the commit distance and short hash, and a drift digest when tracked
	files are dirty (e.g. 4.0.0+3-gb69b243).

	Subcommands:
	  (none)                          Current build version (described above).
	  base                            Nearest semver tag only; prefix stripped and
	                                  no metadata. Falls back to 0.0.0.
	  next major|minor|patch          Next release version from the nearest tag.
	  next prerelease [bump] [label]  Next pre-release version. bump is one of
	                                  major|minor|patch; label is any pre-release
	                                  label (alpha, beta, rc, ...) or empty for -0.
	  history [--full-tags] [--sort]  Every ancestor semver tag, newest first.
	                                  See below for flag details.

	Options:
	  --tolerate-prefix[=LIST]  Comma-separated prefixes tolerated before a tag
	                            (default 'v'); an empty list tolerates none.
	  --oci[=SEP]               Replace '+' in the output with SEP (default '_')
	                            for OCI-compatible image tags.
	  --preserve-metadata       Carry the tag's +build metadata onto next output.
	  --add-metadata=META       Append META to the output's build metadata.

	  --full-tags               When printing history, show full-tags.
	  --sort                    Order history output by semantic version
	                            (highest first). Build metadata is ignored for
	                            ordering; combine with --full-tags to sort raw
	                            tag names by their semantic version component.

	  -h, --help                Show this help and exit.
	HERE
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

# Return the longest tolerated prefix that a given string (tag name) starts
# with (matched case-insensitively), preserving the tag's original casing, or
# nothing if none matches.
# The tolerated prefixes come from the comma-separated TOLERATE_PREFIX list.
tolerated_prefix() {
	local \
		tag=$1 \
		best="" \
		prefix_list=$TOLERATE_PREFIX \
		tag_lower=$(print "$tag" | tr '[:upper:]' '[:lower:]') \
		prefix \
		prefix_lower

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

# Return the tag with any tolerated prefix stripped.
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

# Return the input with every '+' replaced by OCI_PLUS, for OCI-tag-compatible
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

# Return $1 with build metadata $2 attached: start a '+' section if there is
# none, otherwise append with '-' (the same separator convention as the
# build-version metadata).
inject_metadata() {
	case "$1" in
		*+*) print "$1-$2" ;;
		*)   print "$1+$2" ;;
	esac
}

# Return the SHA-1 of stdin, using whichever digest tool is available (GNU
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

# Return the numeric core bumped by the given level, dropping any pre-release.
bump_core_version() {
	# $1=level, $2=major, $3=minor, $4=patch.
	# When bumpting each component, the smaller components go to zero.
	local \
		major=$2 \
		minor=$3 \
		patch=$4
	case "$1" in
		major)
			println "$((major + 1)).0.0"
			;;
		minor)
			println "$major.$((minor + 1)).0"
			;;
		patch)
			println "$major.$minor.$((patch + 1))"
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

# Parse the command line, setting globals based on arguments.
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
			-h|--help)
				help
				exit 0
				;;
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
			--full-tags)
				FULL_TAGS=1
				shift
				;;
			--sort)
				SORT=1
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
		### History ###
		# List all ancestor semver tags
		history)
			MODE="history"
			if [ -n "$2" ]
			then
				die_usage "'history' takes no extra arguments."
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

# Return the most recent valid semantic-version tag reachable from HEAD.
# Rewinds through history past any non-semver tags.
# Returns 0.0.0 when none is found.
resolve_tag() {
	local tag

	# Describe tag does something very similar to what we want already.
	# However it doesn't discrimate between semver compatible tags and not.
	# Here we use --abbrev=0 to strip the commit distance (-1-gffff), so we're
	# grabbing the nearest tag of any type first.
	tag=$(git describe --tags --abbrev=0 2>/dev/null)

	# If there are no tags, use 0.0.0
	if [ -z "$tag" ]
	then
		println 0.0.0
		return
	fi

	# If the nearest tag is not a valid semantic version, rewind to the
	# next-nearest tag.
	# Each step moves strictly backward past a tag, so this always terminates.
	# If we run out of tags we fall back to 0.0.0.
	while ! is_semver "$tag"
	do
		local tag_commit
		tag_commit=$(git rev-list -n 1 "$tag")
		tag=$(git describe --tags --abbrev=0 "$tag_commit^" 2>/dev/null)
		if [ -z "$tag" ]
		then
			println 0.0.0
			return
		fi
	done

	println "$tag"
}


#######################
### Version parsing ###
#######################

# Parse version with the prefix stripped and return the pipe-joined record
# "major|minor|patch|pre_body|cur_label|cur_counter|meta". Returns nothing if
# the input is not a parseable semantic version (the caller validates).
parse_version() {
	local \
		counter \
		parsed \
		build_meta \
		major \
		minor \
		patch \
		pre_body \
		cur_label \
		cur_counter \
		meta

	# Decompose with the canonical SemVer regex — the same definition used to
	# validate the tag; so extraction cannot disagree with validation. The
	# named capture groups yield major/minor/patch/prerelease/buildmetadata,
	# joined with '|'; the optional groups come back empty.
	parsed=$(print "$1" | SEMVER_REGEX="$SEMVER_REGEX" perl -ne '
		if (/$ENV{SEMVER_REGEX}/) {
			print join("|", map { defined $_ ? $_ : "" }
				@+{qw(major minor patch prerelease buildmetadata)});
		}')
	if [ -z "$parsed" ]
	then
		return
	fi
	# Bind parsed results to local variables.
	IFS='|' read -r major minor patch pre_body build_meta <<-HERE
	$parsed
	HERE

	# Build metadata is carried in meta so --preserve-metadata can re-attach it.
	meta=${build_meta:+"+$build_meta"}

	# Split an existing pre-release body into label + counter (concatenated form,
	# e.g. 'alpha0'; a dotted 'alpha.0' is tolerated on input). Stripping the
	# longest prefix ending in a non-digit leaves the trailing run of digits.
	cur_label=""
	cur_counter=0
	if [ -n "$pre_body" ]
	then
		counter=${pre_body##*[!0-9]}
		case "$counter" in
			"")
				# No trailing counter (e.g. '-alpha'): whole body is the label.
				cur_label=$pre_body
				cur_counter=0
				;;
			*)
				cur_counter=$counter
				cur_label=${pre_body%"$counter"}
				cur_label=${cur_label%[-.]}   # strip any trailing separator
				;;
		esac
	fi

	println "$major|$minor|$patch|$pre_body|$cur_label|$cur_counter|$meta"
}


################################
### Next-version computation ###
################################

# Return the next pre-release version.
compute_next_prerelease() {
	local \
		major=$1 \
		minor=$2 \
		patch=$3 \
		pre_body=$4 \
		cur_label=$5 \
		cur_counter=$6

	if [ -n "$BUMP" ]
	then
		# Explicit bump always increments the core and drops any existing
		# pre-release, then starts the counter at 0.
		println "$(bump_core_version "$BUMP" "$major" "$minor" "$patch")-${LABEL}0"
	elif [ -n "$pre_body" ]
	then
		# No bump on an existing pre-release: increment or switch label.
		if [ -z "$LABEL" ] || [ "$LABEL" = "$cur_label" ]
		then
			println "$major.$minor.$patch-$cur_label$((cur_counter + 1))"
		elif is_prerelease_downgrade "$LABEL" "$cur_label"
		then
			die "pre-release label '$LABEL' is a downgrade from '$cur_label'."
		else
			println "$major.$minor.$patch-${LABEL}0"
		fi
	else
		die "'next prerelease' on a non-pre-release version requires a bump level (major|minor|patch)."
	fi
}

# Return the next version, based on MODE and the parsed components.
compute_next() {
	local \
		major=$1 \
		minor=$2 \
		patch=$3 \
		pre_body=$4 \
		cur_label=$5 \
		cur_counter=$6

	case "$MODE" in
		major|minor)
			bump_core_version "$MODE" "$major" "$minor" "$patch"
			;;
		patch)
			if [ -n "$pre_body" ]
			then
				# Finalize the in-progress pre-release: drop it, no numeric bump.
				println "$major.$minor.$patch"
			else
				bump_core_version patch "$major" "$minor" "$patch"
			fi
			;;
		prerelease)
			compute_next_prerelease "$major" "$minor" "$patch" "$pre_body" "$cur_label" "$cur_counter"
			;;
	esac
}


#############################
### Current build version ###
#############################

# Return the current build version: the base version with commit-count/hash and
# dirty-tree drift metadata appended. $1=tag (for the commit count), $2=base
# version.
compute_current_build() {
	local tag=$1
	local version=$2
	local commits
	local short_hash
	local drift_digest

	# Get the number of commits since the last valid tag.
	if [ "$tag" = "0.0.0" ]
	then
		commits=$(git rev-list --count --no-merges HEAD)
	else
		commits=$(git rev-list --count --no-merges "$tag..HEAD")
	fi

	short_hash=$(git rev-parse --short HEAD)

	# If any tracked files have been modified, hash the current diff.
	# `git diff HEAD` shows diff between working tree and HEAD so staged files
	# are included.
	drift_digest=$(git status --porcelain | perl -ne '/^\s?(M|A|D)/ && ($found=1); END {exit !$found}' && git diff HEAD | sha1)

	# Add commit count and hash to the version if there are any commits since the
	# last tag. Add the g prefix to the hash to indicate that it is a Git hash,
	# just like `git describe --tags` does.
	if [ "$commits" -gt 0 ]
	then
		version=$(inject_metadata "$version" "$commits-g$short_hash")
	fi

	# Add a hash of the diff to the version if there are any tracked files that
	# have been modified.
	if [ -n "$drift_digest" ]
	then
		version=$(inject_metadata "$version" "$drift_digest")
	fi

	println "$version"
}


###############
### History ###
###############

# List every semver tag that is an ancestor of HEAD, one per line, in
# topological order.
list_history() {
	git log --topo-order --format='%D' HEAD 2>/dev/null \
		| tr ',' '\n' \
		| perl -ne 's/^\s*tag: // and print' \
		| while IFS= read -r tag
		do
			if is_semver "$tag"
			then
				if [ "$SORT" -eq 1 ]
				then
					# Return two columns to aid in sorting:
					# First column is the version to be compared, and the second column
					# is the text to display.
					# (either the stripped version or the full tag)
					stripped=$(strip_prefix "$tag")
					if [ "$FULL_TAGS" -eq 1 ]
					then
						printf '%s\t%s\n' "$stripped" "$tag"
					else
						printf '%s\t%s\n' "$stripped" "$stripped"
					fi
				elif [ "$FULL_TAGS" -eq 1 ]
				then
					println "$tag"
				else
					println "$(strip_prefix "$tag")"
				fi
			fi
		done
}

# Read "<ver>\t<tag>" rows on stdin and return the tag column ordered by
# the semantic version precedence of the first column.
# (https://web.archive.org/web/20221230095605/https://semver.org/#spec-item-11).
# Build metadata is ignored and equal vers keep their input order.
# (https://web.archive.org/web/20221230095605/https://semver.org/#spec-item-10).
# Descending by default.
sort_tags_by_semver() {
	local perl_prog
	# Use quoted HERE Doc delimiter to avoid internal shell expansion.
	# <<- to strip leading indentation.
	perl_prog=$(cat <<-'PERL'
		my $re = $ENV{SEMVER_REGEX};
		# Default to descending.
		my $dir = $ENV{DIRECTION} || -1;

		# Compare two dot-separated pre-release identifiers.
		# (https://web.archive.org/web/20221230095605/https://semver.org/#spec-item-11)
		sub id_cmp {
			# Two components (strings) are passed in.
			my ($x, $y) = @_;

			my $x_is_num = $x =~ /^[0-9]+$/;
			my $y_is_num = $y =~ /^[0-9]+$/;

			# If both are numeric, do a numeric comparison.
			return $x <=> $y if $x_is_num && $y_is_num;
			# Numeric values are smaller than alphanumeric ones, so if they both
			# are not numeric but the first one is, then the first is smaller.
			return -1 if $x_is_num;
			# And the inverse.
			return  1 if $y_is_num;
			# If both are alphanumeric, then ASCII compare.
			return $x cmp $y;
		}
		# Compare two pre-release identifier lists.
		sub pre_cmp {
			# Two lists of pre-release components are passed in.
			my ($x, $y) = @_;

			# Return 'equal' if both are empty lists.
			return  0 if !@$x && !@$y;        # neither has a pre-release
			# First arg has no pre-release, so it has higher precedence.
			return  1 if !@$x;
			# Second arg has no pre-release, so it has higher precedence.
			return -1 if !@$y;

			# Store shorter pre-release list count in $n to avoid over-running the
			# longer list when comparing.
			my $n = @$x < @$y ? @$x : @$y;
			# For range over the indexes of the shorter list.
			for my $k (0 .. $n - 1) {
				# Compare each pre-release component.
				my $c = id_cmp($x->[$k], $y->[$k]);
				# Return the result of id_cmp if any around to not match.
				# 1 if the component of the first arg was greater, -1 otherwise.
				# Don't return if equal (0)
				return $c if $c
			}
			# If every overlapping element matches, then the longest one is greater.
			return @$x <=> @$y;
		}
		sub sv_cmp {
			# Two row records are passed in.
			my ($x, $y) = @_;

			# Evaluate each part of the record against each part of the other's
			# (except the index), to determine if one is larger than the other.
			$x->{maj} <=> $y->{maj} || $x->{min} <=> $y->{min}
				|| $x->{pat} <=> $y->{pat} || pre_cmp($x->{pre}, $y->{pre});
		}

		# @rows initialized as empty, and $i as undefined.
		# $i++ later will implicitly collapse it to an int of 0 (before
		# incrementing) so no need to initialize.
		my (@rows, $i);

		# Read one line (<STDIN> readline operator) into $line scalar.
		# Wrap in defined() to prevent while evaluating the line itself for
		# truthiness.
		while (defined(my $line = <STDIN>)) {
			chomp $line;
			# Split the row into ver (the sort version) and tag (the display form:
			# either the full tag or just the bare version).
			my ($ver, $tag) = split /\t/, $line, 2;
			my ($maj, $min, $pat, @pre);
			if (defined $ver && $ver =~ /$re/) {
				# Bind capture groups to variables.
				($maj, $min, $pat) = ($+{major}, $+{minor}, $+{patch});
				# If pre-release section exists, split it on . and store in array.
				# Check if defined() to accept '0' prerelease.
				@pre = defined $+{prerelease} ? split(/\./, $+{prerelease}) : ();
				# $+{buildmetadata} intentionally ignored.
				# (https://web.archive.org/web/20221230095605/https://semver.org/#spec-item-10)
			}
			# Push record onto rows, with decomposed parts of the semver, along with
			# an index to preserve the original order for later tie-breaking.
			push @rows, {
				i => $i++,
				tag => $tag,
				maj => $maj,
				min => $min,
				pat => $pat,
				pre => [@pre],
			};
		}

		# The index tiebreak makes stability explicit (Perl sort is not
		# guaranteed stable) and stays ascending, so equal versions keep encounter
		# order in both sort directions.
		print $_->{tag}, "\n" for sort {
			# Comparator evaluates which of the two is greater (with $dir ajusting
			# sort order), or if they are considered identical, it returns whichever
			# has the higher index.
			$dir * sv_cmp($a, $b) || -$dir * ($a->{i} <=> $b->{i})
		} @rows;
	PERL
	)
	SEMVER_REGEX="$SEMVER_REGEX" perl -e "$perl_prog"
}

###################
### Entry point ###
###################

main() {
	# Set globals from arguments.
	parse_args "$@"

	if [ "$MODE" = "history" ]
	then
		if [ "$SORT" -eq 1 ]
		then
			list_history | sort_tags_by_semver
		else
			list_history
		fi
		return 0
	fi

	local \
		tag \
		version \
		output

	tag=$(resolve_tag)
	version=$(strip_prefix "$tag")

	case "$MODE" in
		# No subcommand: the full current build version.
		"")
			output=$(compute_current_build "$tag" "$version")
			;;
		# Just the nearest semver tag, prefix stripped.
		base)
			output=$version
			;;
		# A `next` release/pre-release version, preserving the tag's prefix.
		major|minor|patch|prerelease)
			local \
				prefix \
				major \
				minor \
				patch \
				pre_body \
				cur_label \
				cur_counter \
				meta \
				next
			prefix=$(tolerated_prefix "$tag")

			# Parse version parts and bind to local variables.
			IFS='|' read -r major minor patch pre_body cur_label cur_counter meta <<-HERE
			$(parse_version "$version")
			HERE

			# No major version means the whole version is unparsable.
			if [ -z "$major" ]
			then
				die "base version '$version' is not a parseable semantic version."
			fi

			next=$(compute_next "$major" "$minor" "$patch" "$pre_body" "$cur_label" "$cur_counter") || exit 1
			output="$prefix$next"
			# Re-attach the tag's build metadata when asked to preserve it.
			if [ "$PRESERVE_METADATA" -eq 1 ]
			then
				output="$output$meta"
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
