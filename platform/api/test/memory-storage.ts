import { createHash } from "node:crypto";
import type { ArtifactStorage, StoredObject } from "../src/storage.js";

/**
 * The artifacts bucket, backed by a Map.
 *
 * A presigned URL is a string a test can assert the shape of, so this returns
 * one that names the key it was issued for. That is enough to check the thing
 * worth checking here: that the URL a route hands out is for exactly the key the
 * row describes, and that no path escaped its own prefix on the way.
 *
 * `put` has no counterpart in the real interface on purpose. Nothing in the API
 * ever writes an object; only a holder of a presigned URL does. This exists so a
 * test can simulate that upload happening, or not happening, and see what the
 * completion route makes of it.
 */
export interface MemoryStorage extends ArtifactStorage {
  put(key: string, body: string): void;
  keys(): string[];
  /** Every key a presigned upload URL has been issued for. */
  signedUploads(): string[];
}

export function createMemoryStorage(bucket = "test-artifacts"): MemoryStorage {
  const objects = new Map<string, string>();
  const issued: string[] = [];

  function url(operation: string, key: string, expires: number): string {
    return `https://${bucket}.s3.amazonaws.com/${key}?X-Amz-Operation=${operation}&X-Amz-Expires=${expires}`;
  }

  return {
    async presignUploads(targets, expiresInSeconds) {
      return targets.map((target) => {
        issued.push(target.key);
        return {
          path: target.path,
          url: url("PUT", target.key, expiresInSeconds),
        };
      });
    },

    async presignDownloads(keys, expiresInSeconds) {
      return keys.map((entry) => ({
        path: entry.path,
        url: url("GET", entry.key, expiresInSeconds),
      }));
    },

    async head(key): Promise<StoredObject | null> {
      const body = objects.get(key);
      if (body === undefined) {
        return null;
      }
      return {
        bytes: Buffer.byteLength(body),
        sha256: createHash("sha256").update(body).digest("hex"),
      };
    },

    put(key, body) {
      objects.set(key, body);
    },

    keys() {
      return [...objects.keys()].sort();
    },

    signedUploads() {
      return [...issued];
    },
  };
}
