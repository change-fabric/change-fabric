import { Layout } from "../components/Layout";
import { HOOKS, SKILLS, hookPath, skillPath } from "../reference";

export function Reference() {
  return (
    <Layout>
      <section className="reference-index">
        <p className="eyebrow">Reference</p>
        <h1>Skills and hooks</h1>
        <p className="section-lede">
          Every skill and hook shipped in this repo, generated straight from{" "}
          <code>skills/*/SKILL.md</code> and <code>install.rb</code>'s hook manifest. This page
          can't drift from what's actually installed.
        </p>

        <h2>Skills ({SKILLS.length})</h2>
        <ul className="reference-list">
          {SKILLS.map((skill) => (
            <li key={skill.id} className="reference-list-item">
              <a href={skillPath(skill.id)}>
                <code>{skill.name}</code>
              </a>
              <p>{skill.description}</p>
            </li>
          ))}
        </ul>

        <h2>Hooks ({HOOKS.length})</h2>
        <ul className="reference-list">
          {HOOKS.map((hook) => (
            <li key={hook.id} className="reference-list-item">
              <a href={hookPath(hook.id)}>
                <code>{hook.script}</code>
              </a>
              <p className="reference-events">
                {hook.events.map((event) => (
                  <span key={event} className="status-tag status-current">
                    {event}
                  </span>
                ))}
              </p>
              <p>{hook.description}</p>
            </li>
          ))}
        </ul>
      </section>
    </Layout>
  );
}
