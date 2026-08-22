import { Layout } from "../components/Layout";
import { rawPath, specPath, VERSIONS } from "../spec";

// A minimal versioned-standard index, in the spirit of how w3.org lists versions
// of a spec. Adding a future version requires only one more row in VERSIONS.
export function Versions() {
  return (
    <Layout>
      <section className="versions">
        <p className="eyebrow">CHANGE.md frontmatter spec</p>
        <h1>Versions</h1>
        <p className="section-lede">
          The schema is versioned independently of the platform. Each version has an HTML
          rendering and a raw markdown counterpart.
        </p>
        {/* The four columns do not fit a phone. The table scrolls inside this
            box rather than widening the whole page, which means the box itself
            has to be keyboard focusable. */}
        <div className="scroll-region" tabIndex={0} role="region" aria-label="Spec versions">
          <table className="versions-table">
            <thead>
              <tr>
                <th>Version</th>
                <th>Status</th>
                <th>Date</th>
                <th>Links</th>
              </tr>
            </thead>
            <tbody>
              {VERSIONS.map((entry) => (
                <tr key={entry.version}>
                  <td>
                    <a href={specPath(entry.version)}>{entry.version}</a>
                  </td>
                  <td>
                    <span className={`status-tag status-${entry.status}`}>{entry.status}</span>
                  </td>
                  <td>{entry.date}</td>
                  <td>
                    <a href={specPath(entry.version)}>HTML</a>
                    <span className="sep">/</span>
                    <a href={rawPath(entry.version)}>Markdown</a>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </Layout>
  );
}
