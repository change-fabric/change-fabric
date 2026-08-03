# Releasing

Merging to `main` stages work. Nothing is released until you push the matching
tag.

That is the whole rule. A merge to `main` never creates a GitHub Release and
never deploys the production site. Three independent tracks live in this repo,
each with its own version file, its own tag namespace, and its own publish
workflow, and each is released on its own schedule by pushing one tag.

| Track | Version source of truth | Tag | What the tag publishes |
| --- | --- | --- | --- |
| Toolkit | root `VERSION` | `skills/vX.Y.Z` | A GitHub Release, and downstream the Homebrew tap formula bump |
| Spec | `ChangeSchema::VERSION` in `scripts/change_schema.rb` | `spec/vX.Y.Z` | A GitHub Release whose body is the `CHANGELOG.md` section for that version, with the spec markdown attached |
| Site | `site/VERSION` | `site/vX.Y.Z` | A production deploy of `www.changefabric.org`. No GitHub Release |

## Runbook

### I changed the toolkit (`skills/`, `scripts/`, `install.rb`)

1. Bump the root `VERSION` in your PR. `version-reminder.yml` warns on a PR
   that touches shipped code without bumping it.
2. Merge to `main`. Nothing is released yet.
3. When you want it out, from an up to date `main`:

   ```
   git tag -a "skills/v$(tr -d '[:space:]' < VERSION)" -m "skills/v$(tr -d '[:space:]' < VERSION)"
   git push origin "skills/v$(tr -d '[:space:]' < VERSION)"
   ```

   `release-skills.yml` checks the tag against `VERSION` at the tagged commit
   and publishes a GitHub Release with generated notes. The Homebrew tap
   formula bump runs off the same tag.

### I changed the spec (a `CHANGE.md` frontmatter field)

1. In one PR: bump `ChangeSchema::VERSION`, update the `Schema version` line and
   the field tables in `skills/change/reference/CHANGE-frontmatter-spec.md`,
   freeze the outgoing version into `site/src/archive/<old>.md` and add it to
   `VERSIONS` in `site/src/spec.ts`, add a `## [X.Y.Z]` section to the root
   `CHANGELOG.md`, and add a `site/src/releaseNotes.ts` entry if the version has
   something to say to a human. The drift test
   (`test/change_schema_spec_test.rb`) fails if the doc and the code disagree.
2. Merge to `main`. Nothing is released yet.
3. Cut the release:

   ```
   git tag -a spec/vX.Y.Z -m spec/vX.Y.Z
   git push origin spec/vX.Y.Z
   ```

   `release-spec.yml` refuses the tag unless `X.Y.Z` matches
   `ChangeSchema::VERSION`, the spec doc's `Schema version` line, and a
   `## [X.Y.Z]` section in `CHANGELOG.md`, all at the tagged commit. It then
   publishes a GitHub Release carrying that changelog section as its body and
   the spec markdown as an asset.
4. The live site does not change yet. Deploy it separately, below, when you
   want `www.changefabric.org/spec` to show the new version.

### I changed the site (`site/`)

1. Bump `site/VERSION` in your PR.
2. Merge to `main`. Nothing is deployed yet.
3. Deploy:

   ```
   git tag -a "site/v$(tr -d '[:space:]' < site/VERSION)" -m "site/v$(tr -d '[:space:]' < site/VERSION)"
   git push origin "site/v$(tr -d '[:space:]' < site/VERSION)"
   ```

   `deploy-site.yml` checks the tag against `site/VERSION`, checks that the spec
   version this build would publish as current has already been released as a
   `spec/v*` tag, then builds and publishes to S3 and CloudFront.

A site tag deploys everything sitting on `main` at that commit, not only your
own change. Tag from a `main` you are willing to ship whole.

## Decisions

### 1. Three tracks, three tag namespaces, no shared cadence

The toolkit, the spec and the site change at genuinely different rates and are
consumed by different people. The toolkit ships several times a week to people
who installed it. The spec moves a handful of times a month and is pinned by
repos that have to keep parsing. The site is a rendering, changed for a typo as
readily as for a release. Forcing any two of them onto one version number would
mean either publishing releases that changed nothing for their consumers, or
holding a real change back waiting on an unrelated one.

The three namespaces are `skills/v*`, `spec/v*` and `site/v*`. The slash prefix
keeps them sorted apart in `git tag` output and in the GitHub tag list, and it
is what the existing `skills/v*` tags already do.

`change-schema/v0.1.0` through `change-schema/v0.3.1` are the spec track's
earlier prefix. Those four tags stay in place as immutable history. Nothing new
is cut under that prefix: the public name for this artifact is "the spec"
everywhere else (the `/spec/<version>` site route, the `CHANGELOG.md` heading,
the `--spec` flags), and a fourth vocabulary word for it bought nothing. The
prefix had also lapsed in practice before this document existed, since 0.4.0,
0.5.0 and 0.6.0 all shipped without a tag of any kind.

### 2. Spec releases and site deploys are decoupled in one direction and ordered in the other

A `spec/v*` release never triggers a site deploy, but a `site/v*` deploy fails
unless the spec version it is about to publish as current already has its own
`spec/v*` tag. The live site may lag a spec release. It may never lead one.

Auto-deploying the site off a spec tag was rejected because a site deploy is not
scoped to the spec: it ships every unrelated site change that has landed on
`main` since the last site tag, so making it a side effect of a spec release
would push copy, layout and dependency changes nobody was reviewing for release
that day. The reverse guard costs nothing and closes the only failure that
actually matters, which is `www.changefabric.org/spec` presenting a version as
current when no tag, no release and no permanent artifact exist behind it.

The practical ordering, when a spec release should be visible on the site, is
therefore: merge, push `spec/vX.Y.Z`, push `site/vA.B.C`. The guard makes
getting that order wrong a failed workflow rather than a bad page.

This also settles what `deploy-site.yml` used to conflate. It previously
triggered on pushes touching `skills/change/reference/CHANGE-frontmatter-spec.md`
as well as `site/**`, which made editing the spec a way to deploy the site. Tag
triggering removes path filters entirely, so that coupling is gone.

### 3. Tags are pushed by a human, never by a workflow

`tag-on-version.yml` is deleted. It pushed `skills/v<VERSION>` automatically on
every merge to `main` that touched `VERSION`, which is exactly the behaviour
this document exists to remove: with a publish workflow watching that tag,
merging a version bump would be releasing.

There is a second, independent reason. That workflow pushed the tag with the
default `GITHUB_TOKEN`, and GitHub deliberately does not start new workflow runs
from events created by that token. Any `push: tags: ['skills/v*']` workflow
would therefore never have fired for an automatically created tag. A tag pushed
from a maintainer's own machine does fire them.

No `workflow_dispatch` replacement was added for the same reason: a tag it
pushed would be just as inert.

### 4. The site's version lives in `site/VERSION`, not `site/package.json`

`site/package.json` is `"private": true` and is never published to a registry,
so its `version` field is inert metadata that nothing reads. It stays at
`0.0.0`. A `site/VERSION` file matches the root `VERSION` convention exactly,
which means all three publish workflows read their source of truth the same way
and a contributor learns one habit instead of two.

### 5. A `site/v*` tag creates no GitHub Release

The site has no downloadable artifact and nobody pins a version of it. The tag
itself is the deploy record, and it already answers the only question anyone
asks, which is what commit production is serving. A Release entry would add
noise to the same public releases page that the toolkit and the spec use for
artifacts people really do consume.

### 6. Every publish workflow verifies the tag before it publishes anything

A tag is a string a human typed. Each workflow re-derives the version from the
repository at the tagged commit and fails, before creating a release or touching
production, if the two disagree:

- `release-skills.yml` compares the tag against the root `VERSION` file.
- `release-spec.yml` compares the tag against `ChangeSchema::VERSION`, against
  the spec doc's own `Schema version` line, and against the presence of a
  matching `## [X.Y.Z]` section in `CHANGELOG.md`.
- `deploy-site.yml` compares the tag against `site/VERSION`, and requires the
  `spec/v*` tag for the spec version it would publish to already exist.

These are failures, not warnings. A mismatched tag means the person cutting the
release believed something about the tree that is not true, and the cheapest
place to find that out is before the artifact is public.

### 7. `platform/` is out of scope

`platform/api` and `platform/web` deploy continuously through their own
mechanism and have no external consumer pinning a version. Nothing here changes
for them.

## Operational notes

The site deploy assumes an AWS role through GitHub OIDC. That role's trust
policy (`site/infra/oidc.tf`) matches the workflow's `sub` claim, which changed
from `ref:refs/heads/main` to `ref:refs/tags/site/v*` when the trigger changed.
`terraform apply` in `site/infra` has to run once before the first tag deploy
can authenticate.

The spec is at 0.6.0 with no tag behind it, so the first `site/v*` push will
fail its spec guard until `spec/v0.6.0` is cut. Cutting it is the intended
bootstrap step, not a workaround.
