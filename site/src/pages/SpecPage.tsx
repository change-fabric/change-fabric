import { Layout } from "../components/Layout";
import { ReleaseNotes } from "../components/ReleaseNotes";
import { findVersion, rawPath, specHtml } from "../spec";

export function SpecPage({ version }: { version: string }) {
  const entry = findVersion(version);

  if (!entry) {
    return (
      <Layout>
        <section className="spec-page page-head">
          <h1>Unknown spec version</h1>
          <p className="section-lede">
            No spec is published at version <code>{version}</code>. See the{" "}
            <a href="/spec">list of versions</a>.
          </p>
        </section>
      </Layout>
    );
  }

  return (
    <Layout>
      <section className="spec-page">
        <header className="page-head">
          <div className="page-head-row spec-page-head">
            <div>
              <p className="eyebrow">CHANGE.md frontmatter spec</p>
              <h1>
                Version {entry.version}
                <span className={`status-tag status-${entry.status}`}>{entry.status}</span>
              </h1>
            </div>
            <div className="page-actions">
              <a className="btn" href={rawPath(entry.version)}>
                Raw markdown
              </a>
              <a className="btn btn-quiet" href="/spec">
                All versions
              </a>
            </div>
          </div>
        </header>
        <ReleaseNotes version={entry.version} />
        <div className="spec-body" dangerouslySetInnerHTML={{ __html: specHtml(entry.markdown) }} />
      </section>
    </Layout>
  );
}
