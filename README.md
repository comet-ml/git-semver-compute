# Git SemVer Compute

A simple script to use in your projects to calculcate a
[Semantic Versioning](https://semver.org/) (sem-ver) compliant verion
identifier based on Git Tags and Commits.

## Dependencies

- `git`
- `sh` (POSIX; e.g. `dash`, `busybox ash`, `ksh`, `zsh`, or `bash`)
- `perl`
- a SHA-1 tool: one of `sha1sum`, `shasum`, or `openssl`

## How it Works

- Rewinds the commits in the git tree to find one with a tag that is a valid
  Semantic Version.
- If none is found, the version `0.0.0` is used.
- If the tag is not found on the current commit then metadata will be added to
  the version indicating how many additional commits have been added since the
  tag along with a short commit hash.
  (Mimicing `git describe` behavior but relative to valid sem-ver tags only.)
  (e.g. `4.0.0+1-gb69b243`)
- Additionally, if there are any uncommited changes in tracked files, the diff
  will be hashed and added to the metadata.
  (e.g. `4.0.0+1-gb69b243-f0a876e9043ea35cc5596322db8652fd8bccc44a`)

Tags which begin with a 'v' will have it removed when evaluating the tag as a
version. This tolerated prefix is configurable; see
[Tolerated tag prefixes](#tolerated-tag-prefixes).

## Installing and Running

Download the `calculate-version.sh` script from this repo.

Or, add it to your project as a submodule:

```bash
git submodule add https://codeberg.org/CRThaze/git-semver-compute.git .version
git -C .version checkout 2.0.0
git add .version
git commit -m "Add version calculator submodule"
```

### Makefile

Easily make the current version available in your Makefile like so:

```make
# Use the ?= to allow the version to be overriden easily by passing it in as
# an environment or build variable.
VERSION ?= $(shell ./.version/calculate-version.sh)

$(EXECUTABLE):
  go build -ldflags="-X main.Version=$(VERSION)" -o $(EXECUTABLE) .
```

### Github Actions

```yaml
on: [push]
jobs:
  build:
    steps:
      - name: Compute SemVer from Tags and Commits
        id: version
        run: echo "VERSION=$(${PWD}/.version/calculate-version.sh)" >> $GITHUB_OUTPUT
      - name: Create Archive
        run: tar -czf mycode-${{ steps.version.outputs.VERSION }}.tar.gz .
```

## Usage

Running the script inside your `git` repo, with no arguments, will caluclate
a Semantic Versioning (sem-ver) compliant version relative to the nearest
sem-ver compliant tag (including light-weight tags).

```bash
$ ./calculate-version.sh
4.0.0+1-gb69b243
```

### The Nearest Sem-Ver Tag

Passing the `base` subcommand prints just the nearest valid semver tag, with any
tolerated prefix stripped and no build metadata; regardless of where `HEAD` is
or whether the tree is dirty. If no semver tag is found while rewinding, it falls
back to `0.0.0`.

```
base v1.2.3   calculate-version.sh base -> 1.2.3
no tags       calculate-version.sh base -> 0.0.0
```

### Tag History

Passing the `history` subcommand prints every semver tag that is an ancestor of
the current ref, one per line, in topological order (*newest* first). Tags on
other branches are excluded and non-semver tags are skipped; `--tolerate-prefix`
governs what counts as a semver tag. Each tag is printed prefix-stripped (like
`base`) by default, or as the raw tag name with `--full-tags`.

```
$ calculate-version.sh history
4.0.0
2.1.0+build.99
2.0.0-rc1
1.2.3

$ calculate-version.sh history --full-tags
V4.0.0
2.1.0+build.99
2.0.0-rc1
v1.2.3
```

#### Newest vs Nearest

`history` answers a different question than `base` and `next`. It is a
*topological* (newest-first) listing: it walks parents from `HEAD` and reports
every ancestor semver tag in the order encountered.
`base` (and `next`, and the default build version) instead resolve the
*distance-nearest* release: the semver tag with the fewest commits between it
and `HEAD`, exactly what `git describe` reports.
Since `base` is the minimum-distance tag by definition, `history`'s first line
can only tie or be farther, so the two agree on linear history
(`base` equals the first line) and split only at a **merge**,
where `--topo-order` descends the **newer-dated** parent first rather than the
nearest one; if that side carries the farther tag, they disagree.
This is intentional: the build anchor should be the release you are closest to,
while `history` is the *timeline* of tags.

Linear history, always agree:

```
  ●──────●───────●───────●   ← HEAD
  R      A1      A2      A3
         └ 1.0.0 └ 2.0.0
                   └ nearest, and first in the walk

  base = 2.0.0        history = 2.0.0, 1.0.0     ✓ agree
```

Merge where the newer side carries the *farther* tag, they disagree:

```
   topo walks feature first (F1 is newer-dated) ─┐
                                                 ▼
  feature   ●──────────────●  F1 — tag 1.5.0   (dist 3)  ← history[0]
           ╱                 ╲
  main ●───●───●────●────●────●  M = HEAD
       R   B1  B2   B3    B4   (merge)
                    └ tag 2.0.0  (dist 2)                 ← base

  base = 2.0.0     history = 1.5.0, 2.0.0        ✗ disagree
```

Here `base` takes the distance-2 tag, `2.0.0`. But the newest-first walk
(performed by `history`) enters the `feature` side first
(because `F1` is newer than `B3`) and emits `1.5.0`
(which is technically three commits back, since its one commit remove from B1)
before it ever reaches `2.0.0`. A merge does not *always* split the two:
if the newer-dated branch happens to carry the nearer tag, the newest tag and
the nearest tag are the same one.

Merge where the newer side carries the *nearer* tag, they agree:

```
   topo walks feature first (F1 is newer-dated) ─┐
                                                 ▼
  feature         ●───────●  F1 — tag 2.0.0  (dist 2)  ← history[0] = base
                 ╱         ╲
  main ●───●───●───●───────●  M = HEAD
       R   C1  C2  C3    (merge)
           └ tag 1.5.0  (dist 4)

  base = 2.0.0     history = 2.0.0, 1.5.0        ✓ agree
```

### Computing the Next Version

Passing the `next` subcommand prints the next release or pre-release version,
derived purely from the most recent valid tag (the commit-count and drift
metadata described above are ignored). A leading `v` on the source tag is
preserved in the output.

```
calculate-version.sh next major|minor|patch
calculate-version.sh next prerelease [bump] [label]
```

- `bump` is one of `major`, `minor`, or `patch`.
- `label` is any pre-release label (e.g. `alpha`, `beta`, `rc`, or a custom
  string). Omitting it produces a "plain" numeric pre-release. Pre-releases are
  written in concatenated, 0-indexed form: `-0`, `-alpha0`, `-beta0`, `-rc0`.

#### Plain bumps

Bumps operate on the numeric core and drop any pre-release. The one exception:
`next patch` on a tag that is *already* a pre-release finalizes it (drops the
pre-release without incrementing).

```
base v1.2.3        next major -> v2.0.0   next minor -> v1.3.0   next patch -> v1.2.4
base v1.2.4-alpha0 next major ->  2.0.0   next minor ->  1.3.0   next patch ->  1.2.4 (finalize)
```

#### Pre-releases

`next prerelease` on a tag that is not yet a pre-release requires a bump level.
When a bump is given it always increments the core (starting the counter at 0);
without a bump it increments the existing pre-release, or switches its label
(resetting the counter). Switching to a lower-precedence label is rejected.

```
base v1.2.3        next prerelease patch       -> v1.2.4-0
base v1.2.3        next prerelease patch alpha -> v1.2.4-alpha0
base v1.2.3        next prerelease minor beta  -> v1.3.0-beta0
base v1.2.3        next prerelease             -> error (bump required)
base v1.2.4-alpha0 next prerelease patch       -> v1.2.5-0
base v1.2.4-alpha0 next prerelease             -> v1.2.4-alpha1 (increment)
base v1.2.4-alpha0 next prerelease beta        -> v1.2.4-beta0  (switch + reset)
base v1.2.4-rc1    next prerelease alpha       -> error (downgrade)
```

Label ordering for the downgrade guard follows sem-ver pre-release precedence:
plain sorts below any label, and labels compare alphabetically (so the standard
progression `plain < alpha < beta < rc` holds; custom labels sort
alphabetically).

### Tolerated tag prefixes

By default a leading `v` (e.g. `v1.2.3`) is tolerated in front of a tag when
looking for a valid semantic version. The `--tolerate-prefix` option **replaces**
that default with a comma-separated list of prefixes to tolerate instead. It may
appear anywhere on the command line; before or after a subcommand, or on its
own; and works with every mode. Matching is case-insensitive, and the matched
prefix is stripped from `base`/current output but preserved on `next` output.

```
# Tags shaped like ver2.0.0:
calculate-version.sh --tolerate-prefix=ver base            -> 2.0.0
calculate-version.sh --tolerate-prefix=ver next minor      -> ver2.1.0

# A prefix containing a dash:
calculate-version.sh --tolerate-prefix=release- base       -> 1.4.2   (from release-1.4.2)

# Tolerate several; the longest applicable prefix wins:
calculate-version.sh --tolerate-prefix=v,ver base          -> 3.0.0   (from ver3.0.0)

# Because it replaces the default, a bare 'v' is no longer tolerated here:
calculate-version.sh --tolerate-prefix=ver base            -> 0.0.0   (from v1.0.0)

# An empty list tolerates no prefix at all (strict semver tags only):
calculate-version.sh --tolerate-prefix= base
```

Both `--tolerate-prefix=LIST` and `--tolerate-prefix LIST` are accepted.

### OCI-compatible output

The current build version uses a `+` to introduce build metadata (e.g.
`1.2.3+5-gabc1234`), which is not a legal character in an [OCI](https://github.com/opencontainers/distribution-spec)
image tag. The `--oci` flag replaces `+` in the output with an OCI-safe
separator, defaulting to `_`. Override the replacement with `--oci=SEP`.

```
calculate-version.sh --oci        -> 1.2.3_5-gabc1234-<drift>
calculate-version.sh --oci=--     -> 1.2.3--5-gabc1234-<drift>
calculate-version.sh --oci=       -> 1.2.35-gabc1234-<drift>   (separator removed)
```

Like `--tolerate-prefix`, `--oci` may appear anywhere and combines with any
subcommand. In practice it only affects modes whose output contains a `+`; i.e.
the default current-build version; `base` and `next` output is already tag-safe.
Only the `--oci=SEP` form sets a custom separator; a bare `--oci` always uses `_`.

### Preserving build metadata on `next`

A tag may itself carry sem-ver build metadata (e.g. `1.2.3+build.5`). When
computing a `next` version this metadata is **stripped by default**, since it
describes the old build and is ignored for precedence. Pass `--preserve-metadata`
to carry it onto the computed version instead.

```
# tag 1.2.3+build.5
calculate-version.sh next patch                       -> 1.2.4
calculate-version.sh --preserve-metadata next patch   -> 1.2.4+build.5
calculate-version.sh --preserve-metadata next prerelease patch -> 1.2.4-0+build.5
```

The flag only affects `next` (the `base` and default current-build modes already
keep tag metadata). It combines with `--oci`, which then encodes the preserved
`+` too: `--preserve-metadata --oci next patch` -> `1.2.4_build.5`.

### Injecting metadata

`--add-metadata=META` appends `META` to the output's build metadata in **any**
mode; starting a `+` section if there is none, or appending with `-` if metadata
is already present (the same separator convention the build version uses). It
runs before `--oci`, so an added `+` is encoded along with everything else.

```
# tag 1.2.3 (clean, on the tag)
calculate-version.sh base --add-metadata=ci42          -> 1.2.3+ci42
calculate-version.sh next patch --add-metadata=ci42    -> 1.2.4+ci42

# the default build version already has metadata -> appends with '-'
calculate-version.sh --add-metadata=ci42               -> 1.2.3+5-gHASH-ci42

# with --preserve-metadata it appends to the preserved metadata
# (tag 1.2.3+build.5)
calculate-version.sh --preserve-metadata next patch --add-metadata=ci42
  -> 1.2.4+build.5-ci42
```

Both `--add-metadata=META` and `--add-metadata META` are accepted; an empty
value is a no-op.

