// Human-readable release notes for the CHANGE.md frontmatter spec.
//
// Deliberately separate from the spec text itself. The spec's own "Changelog"
// section is written for someone implementing against the schema and reads like
// a field-set delta; this is written for someone deciding whether a version
// affects them, and says what changed, why, and what they have to do about it.
//
// One entry per version that has something to say. A version with no entry
// simply renders no panel, so adding a version here is optional and never a
// build-time requirement. Keyed by the exact version string used in
// src/spec.ts's VERSIONS, so the current version and every archived version
// resolve their own notes and never each other's.

export interface ReleaseHighlight {
  title: string;
  body: string;
}

export interface ReleaseNote {
  version: string;
  date: string;
  headline: string;
  highlights: ReleaseHighlight[];
  // What an existing CHANGE.md has to do to move to this version. Every
  // release so far has been additive, and saying so plainly is the single
  // most useful line on the page.
  upgrade: string;
}

export const RELEASE_NOTES: Record<string, ReleaseNote> = {
  "0.6.0": {
    version: "0.6.0",
    date: "2026-08-02",
    headline:
      "Findings artifacts publish through a hosted service instead of a bucket each team provisions for itself.",
    highlights: [
      {
        title: "organization, team and platform replace the artifacts block",
        body:
          "A repo now says where its findings go with two slugs and a small platform block: which organization and team it belongs to on the hosted service, and which API origin to talk to. It no longer names a bucket, a region, a CloudFront distribution, a DynamoDB table, or an AWS profile, because none of those are the repo's to state.",
      },
      {
        title: "Publishing is three HTTP calls and no cloud credential",
        body:
          "The publisher declares the run and its files, PUTs each file to the presigned URL that comes back, and says it finished. It authenticates with a team API key and nothing else. There is no AWS SDK on the client, no AWS credential, no bucket name, and no key prefix: the service assigns the prefix, records the run, lists it on the team's findings page, and decides who may open it.",
      },
      {
        title: "A team API key lives in the Keychain, not in the repo or the shell",
        body:
          "ruby scripts/cf_team_join.rb --platform <organization> <team> --stdin stores a contributor's key in the macOS Keychain under service change-fabric-platform, account <organization>/<team>. The publisher reads the environment variable named by api_key_env first and falls back to that entry.",
      },
      {
        title: "One command migrates an already registered team",
        body:
          "ruby scripts/cf_team_migrate.rb --org <slug> --email <you> carries an existing registration onto the platform in a single run: it resolves or creates the organization, a team carrying the old team_id as its legacyTeamId and the old public key, your own membership, one contributor alias per roster entry, a repo link, and a team API key.",
      },
      {
        title: "The legacy identity fields are not going anywhere",
        body:
          "team_id, public_key_ed25519 and contributors are not deprecated and have no removal version. They are what the presence and secret-alert capabilities read: this machine's identity resolves from them, the telemetry Lambdas verify signatures against the public key, and the cf-teams table is keyed on team_id. A migrated repo carries both sets permanently, and they answer different questions: who the contributors are, and where the artifacts go.",
      },
      {
        title: "artifacts is deprecated, not removed",
        body:
          "The per-team S3 bucket block still parses and still resolves a configuration. When both are present, platform wins. The legacy block is removed at 0.7.0, and it is the only thing in contributors_team slated for removal.",
      },
    ],
    upgrade:
      "Additive. A CHANGE.md with no platform block captures no media, builds no bundle, publishes nothing, and audits, reports and gates exactly as it did under 0.5.0. Publishing stays best effort: a publish that fails is a named warning on a run whose verdict the four audit lanes alone decided.",
  },

  "0.5.0": {
    version: "0.5.0",
    date: "2026-08-01",
    headline:
      "contributors_team is documented for the first time, and gains a findings-artifact pipeline.",
    highlights: [
      {
        title: "The third top-level block finally has a spec",
        body:
          "team_id, public_key_ed25519 and contributors[] were always read by the code; until 0.5.0 the field registry covered only two of the three frontmatter blocks. Naming them here closes that gap. No behaviour changed with the documenting.",
      },
      {
        title: "A sweep can publish its findings as a self-contained artifact",
        body:
          "With an artifacts block present, a completed sweep renders one static HTML page carrying the run's contributor and git context, every lane's findings, the browserless lane's full-page screenshots, one recording per viewport, and one annotated PDF per viewport, then uploads the bundle to the team's private S3 bucket behind CloudFront and rebuilds the team index from a DynamoDB listing.",
      },
      {
        title: "Provisioning is one human-run command",
        body:
          "ruby scripts/cf_artifacts_init.rb <team_id> creates the bucket, the distribution, the Basic Auth CloudFront function and the manifest table, then prints the artifacts block filled in.",
      },
      {
        title: "Nothing in the block is a credential",
        body:
          "basic_auth names where the viewer credential lives (an SSM SecureString parameter, a 1Password item reference), never what it is. The CloudFront function that enforces HTTP Basic Auth carries only the SHA-256 digest of that credential, because a CloudFront function has no network access and cannot fetch a secret at request time.",
      },
      {
        title: "Media capture is tunable",
        body:
          "media.screenshots, media.video and media.video_fps decide what the browserless lane captures for the artifact. The recording travels base64 inside that lane's single browserless response, so the frame rate is the main lever on that payload.",
      },
    ],
    upgrade:
      "Additive and default off. A CHANGE.md with no artifacts block captures no media, builds no bundle, uploads nothing, and audits, reports and gates byte for byte as it did under 0.4.0. Publishing is reported separately from the gate, since the four audit lanes are the release decision and the artifact is the evidence attached to it.",
  },

  "0.4.0": {
    version: "0.4.0",
    date: "2026-07-27",
    headline:
      "One repo can register several genuinely different apps, and a ZAP scope can travel between deploy targets.",
    highlights: [
      {
        title: "change_config.apps, a monorepo registry",
        body:
          "Each app gets its own config file, conventionally <app-dir>/CHANGE.app.yml, carrying its own boot, lanes and profiles. This is the axis profiles deliberately does not cover: a profile changes where one audit runs, never what it audits, so a second app with different routes, a different boot and no auth at all cannot be expressed as a profile. An app file's only accepted top-level key is change_config; governance stays repo-wide in the root CHANGE.md.",
      },
      {
        title: "Sweeps and gates became app-aware",
        body:
          "A bare sweep runs every registered enabled app and passes only if all of them pass. --app NAME narrows it, repeats, and composes with --profile. The gate record for a head SHA carries a per-app map and merges across separate --app runs instead of overwriting. change_policy.promotion.<branch>.apps restricts which apps' passes gate a branch; omitted, every registered enabled app is required.",
      },
      {
        title: "Relative ZAP targets",
        body:
          "lanes.zap.targets entries may be relative and resolve against the lane base url, exactly as a11y.routes and browserless.routes already do, so a multi-path ZAP scope is portable across profiles instead of pinning every profile to one committed host. A profile may restate targets for the one case relative paths cannot express, a scope spanning two genuinely distinct services.",
      },
      {
        title: "doctor names the deployment each lane will actually hit",
        body:
          "It prints every enabled lane's resolved target and warns when an absolute lane literal's host differs from the resolved profile's boot target host. The report meta and the gate record now carry the resolved profile and target, not just the requested one, so a report states which deployment it audited. --target-url and --health-url override the resolved target at invocation time, so an ephemeral preview deployment's url never has to be committed.",
      },
    ],
    upgrade:
      "Additive. A CHANGE.md with no apps key parses, runs, reports and gates exactly as it did under 0.3.1. When apps is present the root may not also declare its own boot, lanes or profiles, so adopting the monorepo shape is a verbatim move of the existing block into one app file.",
  },
};

export function releaseNote(version: string): ReleaseNote | undefined {
  return RELEASE_NOTES[version];
}
