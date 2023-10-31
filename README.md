# Git SemVer Compute

A simple script to use in your projects to calculcate a
[SemVer](https://semver.org/) compliant verion identifier based on Git Tags
and Commits.

## Dependencies

- `git`
- `bash`
- `perl`

## How it Works

Rewinds the commits in the git tree to find one with a tag that is a valid
Semantic Version. If none is found, the version `0.0.0` is used. If the tag
is not found on the current commit then metadata will be added to the version
indicating how many additional commits have been added since the tag along
with a short commit hash. Additionally, if there are any uncommited changes in
tracked files, the diff will be hashed and added to the metadata.

Tags which begin with a 'v' will have it removed when evaluating the tag as a
version.

## Usage

Add it to your project as a submodule:

```bash
git submodule add https://gitlab.com/CRThaze/git-semver-compute.git .version
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
