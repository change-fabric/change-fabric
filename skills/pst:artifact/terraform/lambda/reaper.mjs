// Scheduled TTL reaper for the artifacts static-site bucket.
//
// Artifacts live at S3 keys `p/<id>/index.html` (+ a sibling `p/<id>/_source.mdx`).
// On publish each object is tagged with an `expires-at` S3 object tag holding an
// ISO-8601 UTC timestamp, OR the literal string `never`. This function lists the
// `PREFIX`, reads the tag on each `p/<id>/index.html`, and for any artifact whose
// `expires-at` is in the past it deletes the ENTIRE `p/<id>/` prefix (the source
// of truth) and then issues one CloudFront invalidation covering every deleted id.
//
// Dependency-free beyond AWS SDK v3, which ships in the nodejs20.x runtime.

import {
  S3Client,
  ListObjectsV2Command,
  GetObjectTaggingCommand,
  DeleteObjectsCommand,
} from "@aws-sdk/client-s3";
import {
  CloudFrontClient,
  CreateInvalidationCommand,
} from "@aws-sdk/client-cloudfront";

const s3 = new S3Client({});
const cloudfront = new CloudFrontClient({});

// `p/<id>/index.html` -> capture <id>. Anchored so only the artifact landing
// object (not _source.mdx or nested assets) triggers a tag lookup.
const INDEX_KEY_RE = /^p\/([^/]+)\/index\.html$/;
// Defense-in-depth: ids must be opaque slugs before we delete/invalidate by them.
const ID_RE = /^[A-Za-z0-9_-]{1,64}$/;

export const handler = async () => {
  const BUCKET = process.env.BUCKET;
  const DISTRIBUTION_ID = process.env.DISTRIBUTION_ID;
  const PREFIX = process.env.PREFIX || "p/";

  const now = Date.now();
  let scanned = 0;
  let expired = 0;
  const expiredIds = [];

  // 1. Find expired artifact ids by reading the `expires-at` tag on each index.
  let continuationToken;
  do {
    const page = await s3.send(
      new ListObjectsV2Command({
        Bucket: BUCKET,
        Prefix: PREFIX,
        ContinuationToken: continuationToken,
      }),
    );

    for (const obj of page.Contents || []) {
      const match = obj.Key && obj.Key.match(INDEX_KEY_RE);
      if (!match) continue;

      const id = match[1];
      if (!ID_RE.test(id)) {
        console.warn(`skipping malformed id from key: ${obj.Key}`);
        continue;
      }

      scanned += 1;

      try {
        const tagging = await s3.send(
          new GetObjectTaggingCommand({ Bucket: BUCKET, Key: obj.Key }),
        );
        const tag = (tagging.TagSet || []).find((t) => t.Key === "expires-at");

        // Missing tag or `never` -> keep forever.
        if (!tag || !tag.Value || tag.Value === "never") continue;

        const expiresAt = Date.parse(tag.Value);
        if (Number.isNaN(expiresAt)) {
          console.warn(
            `unparseable expires-at "${tag.Value}" on ${obj.Key}; keeping`,
          );
          continue;
        }

        if (expiresAt < now) {
          expired += 1;
          expiredIds.push(id);
        }
      } catch (err) {
        console.error(`failed to read tags for ${obj.Key}: ${err}`);
      }
    }

    continuationToken = page.IsTruncated
      ? page.NextContinuationToken
      : undefined;
  } while (continuationToken);

  // 2. Delete the whole prefix for each expired id (per-id try/catch).
  const deleted = [];
  const invalidationPaths = [];

  for (const id of expiredIds) {
    try {
      const keys = [];
      let token;
      do {
        const page = await s3.send(
          new ListObjectsV2Command({
            Bucket: BUCKET,
            Prefix: `p/${id}/`,
            ContinuationToken: token,
          }),
        );
        for (const obj of page.Contents || []) {
          if (obj.Key) keys.push({ Key: obj.Key });
        }
        token = page.IsTruncated ? page.NextContinuationToken : undefined;
      } while (token);

      // DeleteObjects accepts up to 1000 keys per call.
      for (let i = 0; i < keys.length; i += 1000) {
        const batch = keys.slice(i, i + 1000);
        await s3.send(
          new DeleteObjectsCommand({
            Bucket: BUCKET,
            Delete: { Objects: batch, Quiet: true },
          }),
        );
      }

      deleted.push(id);
      invalidationPaths.push(`/p/${id}/*`);
    } catch (err) {
      console.error(`failed to delete artifact p/${id}/: ${err}`);
    }
  }

  // 3. One CloudFront invalidation covering every deleted id.
  if (invalidationPaths.length > 0 && DISTRIBUTION_ID) {
    try {
      await cloudfront.send(
        new CreateInvalidationCommand({
          DistributionId: DISTRIBUTION_ID,
          InvalidationBatch: {
            CallerReference: `reaper-${Date.now()}`,
            Paths: {
              Quantity: invalidationPaths.length,
              Items: invalidationPaths,
            },
          },
        }),
      );
    } catch (err) {
      console.error(`failed to create CloudFront invalidation: ${err}`);
    }
  }

  const summary = { scanned, expired, deleted };
  console.log(JSON.stringify(summary));
  return summary;
};
