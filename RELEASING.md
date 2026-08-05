# Releasing

Merging to `main` stages work. Nothing is released until you push the matching
tag.

That is the whole rule. A merge to `main` never creates a GitHub Release and
never deploys the production site. Three independent tracks live in this repo,
each with its own tag namespace and its own publish workflow, and each is
released on its own schedule by pushing one tag.

| Track | Version source of truth | Tag | What the tag publishes |
| --- | --- | --- | --- |
| Toolkit | the `skills/v*` tags themselves. No file | `skills/vX.Y.Z` | A GitHub Release, and downstream the Homebrew tap formula bump |
| Spec | `ChangeSchema::VERSION` in `scripts/change_schema.rb` | `spec/vX.Y.Z` | A GitHub Release whose body is the `CHANGELOG.md` section for that version, with the spec markdown attached |
| Site | `site/VERSION` | `site/vX.Y.Z` | A production deploy of `www.changefabric.org`. No GitHub Release |
| Platform app | the `app/v*` tags themselves. No file | `app/vX.Y.Z` | A production deploy of `app.changefabric.org` (once that environment exists; not yet provisioned) |

## Runbook

### I changed the toolkit (`skills/`, `scripts/`, `install.rb`)

There is nothing to edit. The toolkit has no version file; the tag is the
version.

1. Merge your change to `main`. Nothing is released yet, and nothing in the
   tree declares a pending version number.
2. When you want what has accumulated on `main` to go out, look at what the
   last release was and decide the next number yourself:

   ```
   git fetch --tags
   git tag --list 'skills/v*' | sed 's|^skills/v||' \
     | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
   ```

3. From an up to date `main`, tag and push it:

   ```
   git tag -a skills/vX.Y.Z -m skills/vX.Y.Z
   git push origin skills/vX.Y.Z
   ```

   `release-skills.yml` rejects the tag unless it is plain `MAJOR.MINOR.PATCH`,
   newly created rather than moved, and strictly greater than every existing
   `skills/v*` tag. It then publishes a GitHub Release whose notes cover exactly
   the commits since the previous toolkit tag. The Homebrew tap formula bump
   runs off the same tag.

A toolkit tag releases everything on `main` at that commit, so pick the number
from what actually landed since the last one: a new skill or hook is a minor, a
fix to an existing one is a patch.

To find out what version a checkout corresponds to, ask git rather than the
tree:

```
git describe --tags --match 'skills/v*'
```

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

### I changed the platform app (`platform/web`, `platform/api`)

Staging deploys continuously: every merge to `main` ships to
`app.staging.changefabric.org` through `deploy-app-staging.yml`, a sibling
mechanism to this document, not something you trigger yourself.

A production release is a separate, deliberate act, and it needs the
production environment to exist first. There is nothing to edit; like the
toolkit, the platform app has no version file, so the tag is the version.

1. Merge your change to `main`. It goes to staging. Nothing goes to production
   yet.
2. Once `app.changefabric.org` and its AWS role are provisioned, when you want
   what has accumulated on `main` to go out, look at what the last release was
   and decide the next number yourself:

   ```
   git fetch --tags
   git tag --list 'app/v*' | sed 's|^app/v||' \
     | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
   ```

3. From an up to date `main`, tag and push it:

   ```
   git tag -a app/vX.Y.Z -m app/vX.Y.Z
   git push origin app/vX.Y.Z
   ```

   `deploy-app-prod.yml` rejects the tag unless it is plain `MAJOR.MINOR.PATCH`,
   newly created rather than moved, and strictly greater than every existing
   `app/v*` tag. It then builds `platform/web` and publishes it to production.

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
every merge to `main` that touched the root `VERSION` file, which is exactly the
behaviour this document exists to remove: with a publish workflow watching that
tag, merging a version bump would be releasing.

There is a second, independent reason. That workflow pushed the tag with the
default `GITHUB_TOKEN`, and GitHub deliberately does not start new workflow runs
from events created by that token. Any `push: tags: ['skills/v*']` workflow
would therefore never have fired for an automatically created tag. A tag pushed
from a maintainer's own machine does fire them.

No `workflow_dispatch` replacement was added for the same reason: a tag it
pushed would be just as inert.

### 4. The toolkit has no version file. The tag is the version

The root `VERSION` file is deleted. Nothing ever read it: not `install.rb`, not
the `Rakefile`, not a single script, hook or test. Its only three consumers were
release plumbing, and two of them are gone (`tag-on-version.yml`, which used it
as a trigger, and `version-reminder.yml`, which nagged about it). Once a human
pushes the tag, a file restating the same number is not a source of truth, it is
a second place for the truth to be wrong.

So `release-skills.yml` reads the version out of the tag name, and its guardrail
becomes monotonicity instead of agreement. A tag is rejected unless it is plain
`MAJOR.MINOR.PATCH`, was newly created rather than force-moved onto an existing
name, and is strictly greater than every existing `skills/v*` tag. That is a
strictly stronger check than the file comparison it replaces: a file match only
ever caught a typo, while this also catches a re-tag, a version that goes
backwards, and a released version quietly being moved out from under whoever
pinned it.

The comparison is a field-by-field integer sort, not a string sort, because
`0.10.0` sorts below `0.9.0` lexically. It is not `sort -V` either, which is not
SemVer: `sort -V` orders `1.0.0-alpha` after `1.0.0`. Prerelease toolkit tags are
rejected outright rather than mis-ordered. The toolkit has never floated one, and
the Homebrew tap has no channel to put one in.

Two consequences worth stating plainly. The next toolkit release is whatever
number a human picks when they push the next tag; it is no longer pre-declared
anywhere in the tree, and the deleted file's `0.36.2` was never tagged, so it
never meant anything. And the question "what version is this checkout" is now
answered by `git describe --tags --match 'skills/v*'` rather than by reading a
file.

### 5. `version-reminder.yml` is deleted with it

It warned on a PR that touched `scripts/`, `skills/` or `install.rb` without
also touching `VERSION`. With no file to touch, it has no referent.

Nothing is lost, because the workflow contradicted the model in this document
even before the file went away. It asked a contributor to declare release intent
at PR time, when the whole point of tag-gated releases is that release intent is
expressed after merge, by whoever decides that what has accumulated on `main` is
worth shipping. A nudge that fires on every PR touching shipped code, in a repo
where nearly every PR touches shipped code, is noise that trains people to
ignore warnings.

### 6. The site keeps its version file, for now

`site/package.json` is `"private": true` and is never published to a registry,
so its `version` field is inert metadata that nothing reads. It stays at
`0.0.0`. `site/VERSION` is a plain greppable file that `deploy-site.yml` checks
the tag against.

This is now asymmetric with the toolkit track, and the asymmetry is honest
rather than principled: the same argument that removed root `VERSION` applies to
`site/VERSION` almost word for word, since nothing reads it either. It is left
in place because it was not what this change set out to do, and because
`deploy-site.yml`'s guard has a second, unrelated job anyway (checking that the
spec version being published is already released), so that workflow does not
simplify away the way `release-skills.yml` does. Collapsing the site onto its
tag as well is a reasonable follow-up, deliberately not taken here.

### 7. A `site/v*` tag creates no GitHub Release

The site has no downloadable artifact and nobody pins a version of it. The tag
itself is the deploy record, and it already answers the only question anyone
asks, which is what commit production is serving. A Release entry would add
noise to the same public releases page that the toolkit and the spec use for
artifacts people really do consume.

### 8. Every publish workflow checks the tag before it publishes anything

A tag is a string a human typed. Each workflow validates it against something
independent and fails, before creating a release or touching production:

- `release-skills.yml` requires plain semver, a newly created ref, and a version
  strictly above every existing `skills/v*` tag.
- `release-spec.yml` compares the tag against `ChangeSchema::VERSION`, against
  the spec doc's own `Schema version` line, and against the presence of a
  matching `## [X.Y.Z]` section in `CHANGELOG.md`.
- `deploy-site.yml` compares the tag against `site/VERSION`, and requires the
  `spec/v*` tag for the spec version it would publish to already exist.

These are failures, not warnings. A tag that does not check out means the person
cutting the release believed something that is not true, and the cheapest place
to find that out is before the artifact is public.

### 9. `platform/` is out of scope

`platform/web` deploys continuously to staging: `deploy-app-staging.yml` runs
on every push to `main` that touches `platform/web/**`, the same trigger shape
`platform/infra/webapp.tf`'s deploy role already trusts
(`ref:refs/heads/main`). No tag, no version file, no external consumer pinning
a version, matching how this track is out of scope for the rest of this
document. Production now has its own tag-gated track, `app/v*` (see the tracks
table and "I changed the platform app" above), but the environment it deploys
to does not exist yet: that provisioning is a separate piece of work.

`platform/api` has no deploy workflow of its own yet.

## Operational notes

The site deploy assumes an AWS role through GitHub OIDC. That role's trust
policy (`site/infra/oidc.tf`) matches the workflow's `sub` claim, which changed
from `ref:refs/heads/main` to `ref:refs/tags/site/v*` when the trigger changed.
`terraform apply` in `site/infra` has to run once before the first tag deploy
can authenticate.

The spec is at 0.6.0 with no tag behind it, so the first `site/v*` push will
fail its spec guard until `spec/v0.6.0` is cut. Cutting it is the intended
bootstrap step, not a workaround.
