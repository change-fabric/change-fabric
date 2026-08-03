import {
  GetObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

/**
 * The artifacts bucket, as the two operations the routes actually perform:
 * hand out a URL somebody else uses, and ask what an object turned out to be.
 *
 * It is an interface with an S3 implementation for the same reason `store.ts`
 * is: the deployed function runs in a VPC with no internet path, so a unit test
 * that reached the real bucket could not run at all. The in-memory substitute
 * lives in test/.
 *
 * Two things about presigning are worth stating once here rather than
 * rediscovering at each call site.
 *
 * First, a presigned URL carries the SIGNER's authority, not the caller's. The
 * browser or CI job that follows one is anonymous to S3; the request is
 * evaluated against the API Lambda's role. That is why the role needs real
 * s3:PutObject and s3:GetObject on this bucket, scoped to it and nothing else,
 * and why handing one of these URLs to somebody is exactly as consequential as
 * doing the operation for them.
 *
 * Second, the bucket's default encryption is SSE-KMS under alias/cf-platform,
 * and NOTHING here names the key. A presigned PUT that carried explicit
 * server-side-encryption parameters would oblige the uploader to send matching
 * headers, and any mismatch would be a 403 the uploader could do nothing about.
 * Letting the bucket default apply means the object is encrypted the same way
 * either way, with one fewer thing for a caller to get wrong. The signer's role
 * still needs kms:GenerateDataKey and kms:Decrypt, because the signer is who S3
 * evaluates.
 */

export interface UploadTarget {
  path: string;
  key: string;
  contentType: string;
}

export interface PresignedUpload {
  path: string;
  url: string;
}

export interface PresignedDownload {
  path: string;
  url: string;
}

/** What an object actually is, or null when there is no object at that key. */
export interface StoredObject {
  bytes: number;
  sha256: string | null;
}

export interface ArtifactStorage {
  presignUploads(
    targets: UploadTarget[],
    expiresInSeconds: number,
  ): Promise<PresignedUpload[]>;
  presignDownloads(
    keys: { path: string; key: string }[],
    expiresInSeconds: number,
  ): Promise<PresignedDownload[]>;
  head(key: string): Promise<StoredObject | null>;
}

let s3Client: S3Client | undefined;

/** One client for the life of the execution environment, like the SSM one. */
function getS3Client(): S3Client {
  s3Client ??= new S3Client({});
  return s3Client;
}

/**
 * The checksum S3 reports, normalised to the shape the manifest declares.
 *
 * S3 only carries a SHA-256 when the upload asked it to, which a plain
 * presigned PUT does not, so this is usually null and the completion check
 * falls back to comparing sizes. Reading it when it happens to be there costs
 * nothing and makes the stronger check available the day the uploader starts
 * sending one.
 */
function reportedDigest(checksumSha256: string | undefined): string | null {
  if (checksumSha256 === undefined || checksumSha256 === "") {
    return null;
  }
  return Buffer.from(checksumSha256, "base64").toString("hex");
}

export function createS3Storage(bucket: string): ArtifactStorage {
  const client = getS3Client();

  return {
    async presignUploads(targets, expiresInSeconds) {
      return Promise.all(
        targets.map(async (target) => ({
          path: target.path,
          url: await getSignedUrl(
            client,
            new PutObjectCommand({
              Bucket: bucket,
              Key: target.key,
              ContentType: target.contentType,
            }),
            { expiresIn: expiresInSeconds },
          ),
        })),
      );
    },

    async presignDownloads(keys, expiresInSeconds) {
      return Promise.all(
        keys.map(async (entry) => ({
          path: entry.path,
          url: await getSignedUrl(
            client,
            new GetObjectCommand({ Bucket: bucket, Key: entry.key }),
            { expiresIn: expiresInSeconds },
          ),
        })),
      );
    },

    async head(key) {
      try {
        const response = await client.send(
          new HeadObjectCommand({
            Bucket: bucket,
            Key: key,
            ChecksumMode: "ENABLED",
          }),
        );
        return {
          bytes: response.ContentLength ?? 0,
          sha256: reportedDigest(response.ChecksumSHA256),
        };
      } catch (error: unknown) {
        // A missing object is an answer, not a failure: it is precisely what
        // "this upload never finished" looks like, and the completion route
        // records it as a note. Anything else is a real fault and is rethrown.
        const name = (error as { name?: string }).name;
        if (name === "NotFound" || name === "NoSuchKey") {
          return null;
        }
        throw error;
      }
    },
  };
}
