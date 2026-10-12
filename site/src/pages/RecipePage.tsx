import { Layout } from "../components/Layout";
import { CodeBlock } from "../components/CodeBlock";
import { specHtml } from "../spec";
import { findRecipe, needsQaEnv } from "../recipes";

const LOAD_QA_ENV = "set -a; . ./.env.qa; set +a";

export function RecipePage({ slug }: { slug: string }) {
  const recipe = findRecipe(slug);

  if (!recipe) {
    return (
      <Layout>
        <section className="spec-page">
          <h1>Unknown recipe</h1>
          <p className="section-lede">
            No recipe is published at <code>{slug}</code>. See the <a href="/recipes">recipes index</a>.
          </p>
        </section>
      </Layout>
    );
  }

  return (
    <Layout>
      <section className="spec-page recipe-page">
        <div className="spec-page-head">
          <div>
            <p className="eyebrow">Recipe</p>
            <h1>{recipe.title}</h1>
          </div>
          <div className="spec-page-actions">
            <a className="btn btn-quiet" href="/recipes">
              All recipes
            </a>
          </div>
        </div>
        <p className="section-lede">{recipe.summary}</p>
        {recipe.notes && (
          <div className="spec-body" dangerouslySetInnerHTML={{ __html: specHtml(recipe.notes) }} />
        )}

        {needsQaEnv(recipe) && (
          <div className="recipe-run">
            <h2>Loading QA credentials</h2>
            <p>
              Copy <code>.env.qa.example</code> to <code>.env.qa</code>, fill it in, and keep it out
              of git. <code>boot.env_file</code> only reaches the <code>boot.up</code> command; the
              lanes read cf:change's own environment, so export the file in the shell you run it
              from:
            </p>
            <CodeBlock code={LOAD_QA_ENV} label="shell" />
          </div>
        )}

        <h2>Files</h2>
        <div className="recipe-files">
          {recipe.files.map((file) => (
            <CodeBlock key={file.path} code={file.text} label={file.path} />
          ))}
          {recipe.gitignore && <CodeBlock code={`${recipe.gitignore}\n`} label=".gitignore" />}
        </div>
      </section>
    </Layout>
  );
}
