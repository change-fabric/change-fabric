# CHANGE.md recipes

Worked examples of a complete `CHANGE.md` setup, one directory per recipe.
Each directory holds the files a project would commit (the `CHANGE.md`, any app
config, a `.env.qa.example`, committed test-case suites) plus a `recipe.yml`
sidecar naming the title, summary, display order, file order, the `.gitignore`
line to add, and the notes shown above the files. The site renders every recipe
on its Recipes tab straight from these sources, and `test/change_recipes_test.rb`
pins each one to the current `ChangeSchema`, so a schema change that would break
a recipe fails the suite instead of shipping a stale example.
