import { Layout } from "../components/Layout";
import { RECIPES, recipePath } from "../recipes";

export function Recipes() {
  return (
    <Layout>
      <section className="reference-index recipes-index">
        <p className="eyebrow">Recipes</p>
        <h1>Example CHANGE.md specs</h1>
        <p className="section-lede">
          Copyable starting points for common hosting setups. Each recipe is a complete{" "}
          <code>CHANGE.md</code> plus the files it references, validated against the current spec by
          this repo's own tests.
        </p>

        <ul className="reference-list recipes-list">
          {RECIPES.map((recipe) => (
            <li key={recipe.slug} className="reference-list-item">
              <a href={recipePath(recipe.slug)}>{recipe.title}</a>
              <p>{recipe.summary}</p>
            </li>
          ))}
        </ul>
      </section>
    </Layout>
  );
}
