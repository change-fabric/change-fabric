import { Layout } from "../components/Layout";
import { specHtml } from "../spec";
import entries from "../generated/changelog.json";

// The full spec release history, newest first, parsed at build time from the
// root CHANGELOG.md (see scripts/embed-changelog.mjs). Every entry's body
// renders through specHtml(), the same markdown pipeline /spec pages use, so
// its fenced code blocks and tables pick up the same focusable-scroll-region
// wrapping that satisfies axe-core's scrollable-region-focusable rule.
export function Changelog() {
  return (
    <Layout>
      <section className="changelog">
        <p className="eyebrow">CHANGE.md frontmatter spec</p>
        <h1>Changelog</h1>
        <p className="section-lede">
          Every released version of the schema, newest first. Also available as{" "}
          <a href="/changelog.xml">an RSS feed</a>.
        </p>
        <ol className="changelog-list">
          {entries.map((entry) => (
            <li className="changelog-entry" id={`v${entry.version}`} key={entry.version}>
              <h2>
                <a href={`/spec/${entry.version}`}>{entry.version}</a>
                <span className="changelog-date">{entry.date}</span>
              </h2>
              {entry.headline ? <p className="changelog-headline">{entry.headline}</p> : null}
              <div
                className="changelog-body"
                dangerouslySetInnerHTML={{ __html: specHtml(entry.body) }}
              />
            </li>
          ))}
        </ol>
      </section>
    </Layout>
  );
}
