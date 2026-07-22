# git-semver-compute — mirror control branch

This `__mirror` branch holds **only** the automation that keeps this GitHub
repository mirrored from its upstream:

> https://codeberg.org/CRThaze/git-semver-compute

It is the repository's **default branch on purpose**. GitHub only runs
`schedule` / `workflow_dispatch` workflows from the default branch, and the
mirror must live on a branch upstream never overwrites — so this control branch
has to be the default. There is no project code here.

## Where the code is

On [`main`](../../tree/main), kept in sync with upstream by
[`.github/workflows/mirror.yml`](.github/workflows/mirror.yml) (daily at 03:00
UTC, plus on demand from the **Actions** tab). Both branches and tags are
mirrored; this `__mirror` branch is left untouched.

## Using it as a submodule

Because the default branch is `__mirror`, point submodules at `main` explicitly:

    git submodule add -b main https://github.com/comet-ml/git-semver-compute.git .version

Submodules that are already added are unaffected — they pin a specific commit,
so the default branch is irrelevant once it has been recorded.
