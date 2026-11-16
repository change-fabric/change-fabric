# browserless-cf: the upstream browserless Chromium image plus the OFL faces
# cf:walkthrough, cf:diagram, and the lint lanes render with. Built and
# published only by .github/workflows/release-image.yml on a human-pushed
# image/vX.Y.Z tag. The FROM below must equal BROWSERLESS_UPSTREAM in
# scripts/change_docker.rb (test/release_image_workflow_test.rb asserts it).
FROM ghcr.io/browserless/chromium:v2.38.1@sha256:78afaada9f7b049783bfed624e6b5e9a2d3438fc04bb46801ed777e82ae1501f

USER root
COPY fonts.lock /tmp/fonts.lock
# Fetch every locked file, then verify all of them in one sha256sum -c pass: a
# changed or truncated upstream file fails the build instead of shipping.
RUN set -eu; \
    dest=/usr/share/fonts/truetype/cf; \
    : > /tmp/fonts.sha256; \
    grep -Ev '^[[:space:]]*(#|$)' /tmp/fonts.lock > /tmp/fonts.list; \
    while read -r sha path url; do \
      mkdir -p "$dest/$(dirname "$path")"; \
      curl -fsSL --retry 3 -o "$dest/$path" "$url"; \
      printf '%s  %s\n' "$sha" "$dest/$path" >> /tmp/fonts.sha256; \
    done < /tmp/fonts.list; \
    sha256sum -c /tmp/fonts.sha256; \
    rm -f /tmp/fonts.lock /tmp/fonts.list /tmp/fonts.sha256; \
    fc-cache -f; \
    fc-list | grep -q 'Source Serif 4'; \
    fc-list | grep -q 'Inter'; \
    fc-list | grep -q 'JetBrains Mono'
USER blessuser
