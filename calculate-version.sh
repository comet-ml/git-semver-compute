#!/bin/bash

# RegEx source:
# https://web.archive.org/web/20221230095605/https://semver.org/#is-there-a-suggested-regular-expression-regex-to-check-a-semver-string
SEMVER_REGEX='^(?P<major>0|[1-9]\d*)\.(?P<minor>0|[1-9]\d*)\.(?P<patch>0|[1-9]\d*)(?:-(?P<prerelease>(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+(?P<buildmetadata>[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$'

# Get the most recent tag in Git.
tag=$(git describe --tags --abbrev=0 2>/dev/null)

# If there are no tags, use 0.0.0
if [ -z "$tag" ]
then
	tag=0.0.0
fi

# If the most recent tag is not a valid semantic version, rewind until we find one.
while ! (echo $tag | perl -p -e 's/^v//i' | perl -ne "/$SEMVER_REGEX/ && (\$found=1); END {exit !\$found}")
do
	# # Get the hash for the most recent tag
	tag_hash=$(git rev-list -n 1 $tag)

	# Get the hash for the commit before the latest tag
	previous_tag_hash=$(git rev-list $tag_hash | sed '2q;d')

	# Rewind commits to the previous tag.
	while (git describe --tags $previous_tag_hash 2>/dev/null | perl -ne '/.+?-\d+-g[[:xdigit:]]{7}$/ && ($found=1); END {exit !$found}')
	do
		tag_hash=$previous_tag_hash
		previous_tag_hash=$(git rev-list $tag_hash | sed '2q;d')
		# If we've reached the beginning of the commit history, break out of the
		# loop. This should never happen.
		if [ -z "$previous_tag_hash" ]
		then
			break
		fi
	done
	# Get the tag, or return 0.0.0 if there are no tags or if we've reached the
	# end of the commit history.
	tag=$(git describe --tags $previous_tag_hash --abbrev=0 2>/dev/null || echo 0.0.0)
done

# Strip the leading 'v' from the tag, if it exists.
VERSION=$(echo $tag | perl -p -e 's/^v//i')

# Get the number of commits since the last valid tag.
if [ "$tag" == "0.0.0" ]
then
	commits=$(git rev-list --count --no-merges HEAD)
else
	commits=$(git rev-list --count --no-merges $tag..HEAD)
fi

short_hash=$(git rev-parse --short HEAD)

# If any tracked files have been modified, add a hash of the diff to the
# version.
drift_digest=$(git status --porcelain | perl -ne '/^\s?(M|A|D)/ && ($found=1); END {exit !$found}' && git diff HEAD | sha1sum | awk '{print $1}')

# Determine if the version already has metadata.
has_metadata=$(echo $VERSION | perl -ne '/\+/ && ($found=1); END {exit !$found}' && echo 1 || echo 0)

# Add commit count and hash to the version if there are any commits since the
# last tag.
if [ $commits -gt 0 ]
then
	# If the version already has metadata, add a dash. Otherwise, add a plus.
	if [ $has_metadata -eq 0 ]
	then
		VERSION=$VERSION+
		has_metadata=1
	else
		VERSION=$VERSION-
	fi
	# Add the g prefix to the hash to indicate that it is a Git hash.
	# Just like `git describe --tags` does.
	VERSION=$VERSION$commits-g$short_hash
fi

# Add a hash of the diff to the version if there are any tracked files that
# have been modified.
if [ -n "$drift_digest" ]
then
	# If the version already has metadata, add a dash. Otherwise, add a plus.
	if [ $has_metadata -eq 0 ]
	then
		VERSION=$VERSION+
		has_metadata=1
	else
		VERSION=$VERSION-
	fi
	VERSION=$VERSION$drift_digest
fi

# Print the version.
echo -n $VERSION
