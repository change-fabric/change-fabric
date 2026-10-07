---
name: cf:laravel
description: Laravel convention-first rubric for validation, authorization, Eloquent safety, queues, and config. Auto-applied by the cf shim on every PHP change in a Laravel project; also invocable directly.
auto:
  extensions: [php]
  require: ["**/artisan"]
  detect: ["**/artisan"]
---

# Laravel Cheat Sheet

Sources: Laravel docs (laravel.com/docs); Laravel framework repo (github.com/laravel/framework)

Question: Is this the simplest conventional Laravel solution, validated and authorized on the server?

Favor:
- Framework primitives (Form Requests, policies, gates, casts, scopes, jobs, API Resources) over custom infrastructure
- Controllers that accept validated input, authorize, coordinate, and respond
- Extracting an action or service only when the work is complex, reused, transactional, spans models or external systems, or is a real business operation
- Form Requests for non-trivial validation; `$request->validated()` or `safe()` over `$request->all()`
- Policies and gates, plus query scoping so users cannot fetch records they may not see
- Explicit relationships; `with()` eager loading to prevent N+1; `select()` when a query is expensive
- `Model::shouldBeStrict()` (or `preventLazyLoading()`) outside production
- `chunk()`, `lazy()`, `cursor()`, or `paginate()` for tables that grow
- `DB::transaction()` for atomic multi-writes, with an attempts count where deadlocks are possible
- Queued jobs for mail, external calls, imports, and media; retry-safe, idempotent, with tries, timeout, and backoff set
- `afterCommit()` (or `ShouldQueueAfterCommit`) when a job depends on a transaction's writes
- Passing model ids or models (`SerializesModels`) to jobs, not large object graphs
- API Resources and pagination for public responses
- `config()` in application code; `env()` only inside a `config/*.php` file (the root app's or a nested app's)
- Migrations for every schema change, with constraints, foreign keys, and indexes from real access patterns
- Feature tests for HTTP and workflows; factories over hand-built fixtures

Avoid:
- Automatic Action, Service, Repository, DTO, or Interface layers; `FooRepositoryInterface` wrapping Eloquent with no need
- One-method wrapper classes that add no abstraction
- Blind mass assignment (`create($request->all())`, `$guarded = []` without validated input)
- `Model::all()` on a table that can grow
- Business workflows hidden in observers, model events, accessors, mutators, or listener chains
- Business logic in Blade templates
- Authorization only in the UI
- Synchronous external calls in latency-sensitive request paths
- Mocking Eloquent or the framework to turn a feature test into a unit test
- Fighting framework conventions without a concrete benefit

Exception: Facades are fine; prefer constructor injection where an explicit dependency helps clarity or testing.

CI (mechanically enforced; run through `./vendor/bin/sail` or the project's Compose PHP service):
- `php artisan test` passes
- `vendor/bin/pint --test` passes
- `vendor/bin/phpstan analyse` (Larastan) passes, with `noEnvCallsOutsideOfConfig: true` under `parameters:` in `phpstan.neon` (off by default; it flags `env()` outside `config/`)

Review-time (no tool checks these):
- Every mutation validated and authorized; authorization boundaries tested
- `APP_DEBUG=false` in production; workers restarted after deploys; migrations run deliberately

Agent protocol:
1. Reach for the Laravel primitive before writing infrastructure.
2. Validate with a Form Request and authorize with a policy on every mutation.
3. Check new queries for N+1 and unbounded results.
4. Queue slow or failure-prone work after the transaction commits.
5. Preserve behavior.
