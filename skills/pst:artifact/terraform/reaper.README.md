# Artifact TTL reaper

A scheduled Lambda that **destroys expired artifacts** from the static-site S3
bucket - the source of truth - and invalidates CloudFront for them.

## TTL self-destruct is ON by default

`enable_reaper = true` by default. TTL self-destruct is a default behavior of
this platform: artifacts published with an expiry will be permanently deleted
once that expiry passes. There is no recycle bin - when the reaper runs, the
artifact's S3 objects are gone.

## How it works

1. On publish, `publish.py` tags each of an artifact's objects
   (`p/<id>/index.html`, `p/<id>/_source.mdx`, …) with an S3 object tag
   `expires-at` set to either an ISO-8601 UTC timestamp or the literal string
   `never`.
2. On the schedule, the reaper Lambda lists the `p/` prefix and reads the
   `expires-at` tag on each `p/<id>/index.html`.
   - Tag missing or `never` → kept forever.
   - Tag is a timestamp in the past → expired.
3. For every expired id it deletes the **entire `p/<id>/` prefix** (all objects)
   via batched `DeleteObjects`, then issues **one** CloudFront invalidation
   covering all deleted ids (`/p/<id>/*`).

Each id is processed in its own try/catch, so one failure does not abort the
run. The Lambda logs and returns a summary: `{ scanned, expired, deleted: [...ids] }`.

## Schedule

`reaper_schedule` is an EventBridge schedule expression, default `"rate(1 day)"`.

```hcl
reaper_schedule = "rate(12 hours)"      # twice a day
reaper_schedule = "cron(0 7 * * ? *)"   # daily at 07:00 UTC
```

## Cost

Negligible. One short Lambda invocation per schedule tick (default once/day,
128–256 MB, well under a second of compute unless thousands of artifacts exist),
a bounded (14-day) CloudWatch log group, and the usual S3 List/GetTagging/Delete
and a single CloudFront invalidation per run (CloudFront grants 1,000 free
invalidation paths per month). In practice this rounds to $0.

## Disable or change cadence

Disable entirely (artifacts then live forever, ignoring `expires-at`):

```hcl
enable_reaper = false
```

When disabled no reaper resources are created and both reaper outputs
(`reaper_function_name`, `reaper_schedule_effective`) are `null`.

Change cadence by setting `reaper_schedule` (see above) and re-applying.
