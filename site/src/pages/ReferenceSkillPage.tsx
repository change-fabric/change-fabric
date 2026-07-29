import { Layout } from "../components/Layout";
import { specHtml } from "../spec";
import { findSkill } from "../reference";

export function ReferenceSkillPage({ id }: { id: string }) {
  const skill = findSkill(id);

  if (!skill) {
    return (
      <Layout>
        <section className="spec-page">
          <h1>Unknown skill</h1>
          <p className="section-lede">
            No skill is published at <code>{id}</code>. See the <a href="/reference">reference index</a>.
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
            <p className="eyebrow">Skill reference</p>
            <h1>
              <code>{skill.name}</code>
            </h1>
          </div>
          <div className="spec-page-actions">
            <a className="btn btn-quiet" href="/reference">
              All skills and hooks
            </a>
          </div>
        </div>
        <p className="section-lede">{skill.description}</p>
        {skill.autoBasenames.length > 0 && (
          <p>
            Auto-applied on:{" "}
            {skill.autoBasenames.map((basename, index) => (
              <span key={basename}>
                {index > 0 && ", "}
                <code>{basename}</code>
              </span>
            ))}
          </p>
        )}
        <div className="spec-body" dangerouslySetInnerHTML={{ __html: specHtml(skill.body) }} />
      </section>
    </Layout>
  );
}
