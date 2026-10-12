import { Layout } from "../components/Layout";
import { CopyLink } from "../components/CopyLink";
import { CURRENT_VERSION, specHtml } from "../spec";
import entries from "../generated/changelog.json";

const SITE_ORIGIN = "https://www.changefabric.org";

// The full spec release history, newest first, parsed at build time from the
// root CHANGELOG.md (see scripts/embed-changelog.mjs). Every entry's body
// renders through specHtml(), the same markdown pipeline /spec pages use, so
// its fenced code blocks and tables pick up the same focusable-scroll-region
// wrapping that satisfies axe-core's scrollable-region-focusable rule.
//
// Layout: a left date column carries a sticky date marker per entry; the
// entry sits to its right, and entries are separated by hairlines.
export function Changelog() {
  return (
    <Layout>
      <section className="changelog">
        <header className="page-head">
          <p className="eyebrow">CHANGE.md frontmatter spec</p>
          <h1>Changelog</h1>
          <p className="section-lede">
            Every released version of the schema, newest first. Also available as{" "}
            <a href="/changelog.xml">an RSS feed</a>.
          </p>
        </header>
        <ol className="changelog-list">
          {entries.map((entry) => (
            <li className="changelog-entry" id={`v${entry.version}`} key={entry.version}>
              <div className="changelog-rail">
                <time className="changelog-date" dateTime={entry.date}>
                  {entry.date}
                </time>
              </div>
              <article className="changelog-card">
                <div className="changelog-meta">
                  <h2 className="changelog-version">
                    <a href={`/spec/${entry.version}`}>{entry.version}</a>
                  </h2>
                  <span
                    className={
                      entry.version === CURRENT_VERSION
                        ? "status-tag status-current"
                        : "status-tag"
                    }
                  >
                    {entry.version === CURRENT_VERSION ? "current" : "superseded"}
                  </span>
                  {entry.sections.map((section) => (
                    <span className="changelog-tag" key={section}>
                      {section}
                    </span>
                  ))}
                  <CopyLink
                    url={`${SITE_ORIGIN}/changelog#v${entry.version}`}
                    label={`Copy link to ${entry.version}`}
                  />
                </div>
                {entry.headline ? (
                  <p className="changelog-headline">{entry.headline}</p>
                ) : null}
                <div
                  className="changelog-body"
                  dangerouslySetInnerHTML={{ __html: specHtml(entry.body) }}
                />
              </article>
            </li>
          ))}
        </ol>
      </section>
    </Layout>
  );
}
