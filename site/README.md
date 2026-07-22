# changefabric.org site

A minimal React + Vite + TypeScript static single-page site for the change
fabric platform, served at https://www.changefabric.org (the apex
https://changefabric.org 301-redirects to it).

The page embeds the canonical CHANGE.md frontmatter spec
(`skills/change/reference/CHANGE-frontmatter-spec.md`) at build time via
`scripts/embed-spec.mjs`, so the rendered spec and its version always match what
shipped. Nothing is fetched at runtime.

## Develop

```
cd site
npm install
npm run dev
```

## Build

```
npm run build      # runs embed-spec, tsc --noEmit, then vite build -> dist/
```

## Deploy

Infrastructure is Terraform under `infra/` (S3 site bucket, two CloudFront
distributions, an ACM cert, and Route53 records in the existing hosted zone),
with remote state in an S3 backend. See `infra/README.md`. After
`terraform apply`, publish the build with `infra/deploy.sh`, which syncs `dist/`
to the site bucket and invalidates CloudFront.
