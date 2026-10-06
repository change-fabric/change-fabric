---
name: cf:php
description: Modern PHP rubric for native types, explicit boundaries, safe defaults, and restraint in existing codebases. Auto-applied by the cf shim on every PHP change; also invocable directly.
auto:
  extensions: [php]
  basenames: [composer.json]
  detect: [composer.json, .php-version]
---

# PHP Cheat Sheet

Sources: PHP manual (php.net/manual); PHP-FIG PER Coding Style; PHPStan and Psalm docs

Question: Is this typed, explicit, and safe at its boundaries, and does it match the code already here?

Defaults, not dogma. Match the conventions already in the repository unless they cause a concrete
correctness, security, performance, or maintainability problem.

Favor:
- Native types on parameters, returns, properties, and constants; `mixed` only when nothing narrower fits
- `readonly` properties or classes for immutable data; enums for finite sets of values
- Constructor property promotion, `match` over long `switch`, named arguments only where they clarify
- DTOs or value objects over large associative arrays once data has structure or behavior
- Validating and normalizing external input at the boundary; invalid states hard to represent
- Composition over inheritance; interfaces only at real boundaries or with several implementations
- Domain exceptions callers can tell apart; catch only to recover, translate, add context, or clean up
- Prepared statements or parameter binding; transactions for atomic multi-write work
- `password_hash()`/`password_verify()`; maintained libraries over custom crypto
- `declare(strict_types=1);` in a new file only when its neighbors carry it; never retrofit

Avoid:
- SQL built by concatenating or interpolating untrusted input
- Silently swallowed exceptions, or `catch (\Throwable)` with no deliberate reason
- PHPDoc that only repeats a native type
- Magic strings where an enum fits; boolean-parameter soup
- Global mutable state, god classes, deep inheritance, excessive static methods
- Methods that hide I/O or mutate unrelated state
- Interfaces, layers, or abstractions added for hypothetical future needs
- Committed secrets, keys, or tokens; secrets or personal data in logs
- Unescaped output (escape for the destination context)

Scope: in `*.blade.php` views the class, type, and strict_types rules do not apply; review those
only for escaping, security, and logic that belongs outside the template.

Restraint (applies to every PHP and Laravel change):
- Keep the change local; no refactor of unrelated code, no drive-by formatting
- No new pattern, dependency, or layer without a present need; delete before abstracting
- Preserve backwards compatibility unless the break is intended and stated
- When deviating from a project convention for a good reason, make the reason visible

CI (mechanically enforced; run the tools inside the project's PHP container, Sail or Compose, not a host PHP):
- `composer validate --strict` and `composer audit` pass; `composer.lock` committed for applications
- The repo's configured formatter passes (`vendor/bin/pint --test` in Laravel apps, otherwise `vendor/bin/php-cs-fixer fix --dry-run --diff` with PER); the configured formatter wins over PER
- `vendor/bin/phpstan analyse` (or Psalm) passes at the project's level
- `vendor/bin/phpunit` or `vendor/bin/pest` passes

Review-time (no tool checks these):
- Exceptions not swallowed; catches are deliberate
- Tests cover behavior and failure paths, not implementation details, and are deterministic
- No speculative abstraction

Agent protocol:
1. Read the neighboring files and match their style, structure, and strict_types use.
2. Type everything the language can express.
3. Validate at the boundary; bind every query parameter.
4. Make the smallest change that solves the problem.
5. Preserve behavior.
