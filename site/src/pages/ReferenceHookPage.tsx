import { Layout } from "../components/Layout";
import { Breadcrumbs } from "../components/Breadcrumbs";
import { SourceLink } from "../components/SourceLink";
import { findHook } from "../reference";

const REPO_URL = "https://github.com/change-fabric/change-fabric";

export function ReferenceHookPage({ id }: { id: string }) {
  const hook = findHook(id);

  if (!hook) {
    return (
      <Layout>
        <section className="spec-page page-head">
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
        <header className="page-head">
          <div className="page-head-row spec-page-head">
            <div>
              <Breadcrumbs group="hooks" label="Hooks" />
              <h1>
                <code>{hook.script}</code>
              </h1>
            </div>
            <div className="page-actions">
              <SourceLink
                href={`${REPO_URL}/blob/main/scripts/${hook.script}`}
                label="View source"
                title={`${hook.script} source on GitHub`}
              />
            </div>
          </div>
          <p className="section-lede detail-lede">{hook.description}</p>
        </header>
        <p className="reference-events">
          <span className="eyebrow">Fires on</span>
          {hook.events.map((event) => (
            <code key={event}>{event}</code>
          ))}
        </p>
      </section>
    </Layout>
  );
}
