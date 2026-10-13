import { Layout } from "../components/Layout";
import { specHtml } from "../spec";
import { SourceLink } from "../components/SourceLink";
import { findSkill, skillSourceUrl } from "../reference";

export function ReferenceSkillPage({ id }: { id: string }) {
  const skill = findSkill(id);

  if (!skill) {
    return (
      <Layout>
        <section className="spec-page page-head">
          <h1>Unknown skill</h1>
          <p className="section-lede">
            No skill is published at <code>{id}</code>. See the <a href="/reference">reference index</a>.
          </p>
        </section>
      </Layout>
    );
  }

  const sourceUrl = skillSourceUrl(skill);

  return (
    <Layout>
      <section className="spec-page">
        <header className="page-head">
          <div className="page-head-row spec-page-head">
            <div>
              <p className="eyebrow">Skill reference</p>
              <h1>
                <code>{skill.name}</code>
              </h1>
            </div>
            <div className="page-actions">
              {sourceUrl && (
                <SourceLink href={sourceUrl} label="View source" title={`${skill.name} source on GitHub`} />
              )}
              <a className="btn btn-quiet" href="/reference">
                All skills and hooks
              </a>
            </div>
          </div>
          <p className="section-lede detail-lede">{skill.description}</p>
        </header>
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
