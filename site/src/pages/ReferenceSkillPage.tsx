import { Layout } from "../components/Layout";
import { specHtml } from "../spec";
import { SourceLink } from "../components/SourceLink";
import { Breadcrumbs } from "../components/Breadcrumbs";
import { findSkill, skillSourceUrl } from "../reference";

const GROUP_LABELS: Record<string, string> = {
  lanes: "Lanes",
  rubrics: "Rubrics",
  workflow: "Workflow",
  modes: "Modes",
};

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
              <Breadcrumbs group={skill.group} label={GROUP_LABELS[skill.group] ?? "Skills"} />
              <h1>
                <code>{skill.name}</code>
              </h1>
            </div>
            <div className="page-actions">
              {sourceUrl && (
                <SourceLink href={sourceUrl} label="View source" title={`${skill.name} source on GitHub`} />
              )}
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
