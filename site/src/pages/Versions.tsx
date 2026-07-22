import { Layout } from "../components/Layout";
import { rawPath, specPath, VERSIONS } from "../spec";

// A minimal versioned-standard index, in the spirit of how w3.org lists versions
// of a spec. Adding a future version is one more row in VERSIONS; this page does
// not change.
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
      </section>
    </Layout>
  );
}
