import { Layout } from "../components/Layout";
import { findHook } from "../reference";

const REPO_URL = "https://github.com/pstaylor-patrick/change-fabric";

export function ReferenceHookPage({ id }: { id: string }) {
  const hook = findHook(id);

  if (!hook) {
    return (
      <Layout>
        <section className="spec-page">
          <h1>Unknown hook</h1>
          <p className="section-lede">
            No hook is published at <code>{id}</code>. See the <a href="/reference">reference index</a>.
          </p>
        </section>
      </Layout>
    );
  }

  return (
    <Layout>
      <section className="spec-page">
        <div className="spec-page-head">
          <div>
            <p className="eyebrow">Hook reference</p>
            <h1>
              <code>{hook.script}</code>
            </h1>
          </div>
          <div className="spec-page-actions">
            <a className="btn" href={`${REPO_URL}/blob/main/scripts/${hook.script}`}>
              Source
            </a>
            <a className="btn btn-quiet" href="/reference">
              All skills and hooks
            </a>
          </div>
        </div>
        <p className="reference-events">
          {hook.events.map((event) => (
            <span key={event} className="status-tag status-current">
              {event}
            </span>
          ))}
        </p>
        <p className="section-lede">{hook.description}</p>
      </section>
    </Layout>
  );
}
