---
name: cf:rails
description: Rails convention-over-configuration rubric. Auto-applied by the cf shim in Rails projects; also invocable directly.
auto:
  extensions: [erb, jbuilder]
  basenames: [routes.rb, application_controller.rb, application_record.rb, application_job.rb, application_mailer.rb, schema.rb]
  detect: [bin/rails, config/application.rb, config/routes.rb, config/environment.rb]
---

# Rails Cheat Sheet

Sources: Ruby on Rails Guides; DHH, *The Rails Doctrine*

Primary question:
Does this follow Rails conventions while remaining easy to change?

| Favor | Over |
|------------|-----------|
| Convention over configuration | Bespoke configuration |
| Skinny controllers | Fat controllers |
| Cohesive models | God models |
| RESTful resources | Ad hoc actions |
| Active Record associations and scopes | Duplicated queries |
| Service, query, form, and policy objects when complexity grows | Premature abstraction |
| Framework defaults | Custom framework replacements |

Red flags:
- Massive controllers
- God models
- Duplicated queries
- Callback chains
- N+1 queries
- Business logic in views or helpers
- Custom framework replacements

Agent protocol:
1. Prefer Rails conventions.
2. Keep responsibilities clear.
3. Extract complexity only when justified.
4. Preserve behavior.
