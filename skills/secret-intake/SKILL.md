---
name: cf:secret-intake
group: workflow
description: Stages a secret the user pastes into a short-lived upload page in their own AWS account, so the value never passes through chat, argv, or a log. Prints status lines only; the agent never reads the value.
---

# CF Secret Intake

Trigger: `/cf:secret-intake`, or any time a task needs a secret the user has
not yet put on this machine. Never ask the user to paste a secret into chat.

## Stage a secret

Launch intake with `run_in_background` and relay only the page link line:

```
ruby ~/.claude/cf/bin/secret_intake.rb intake --name OPENAI_API_KEY \
  --profile personal --region us-east-1 --validate openai --ttl 1h
```

`--name` is the env-style name to stage under. `--validate` takes a provider
from `config/providers.yml` or `none` (the default). `--ttl` defaults to 1h,
caps at 12h, and is also capped by the AWS session's own expiry. `--profile`
and `--region` default to `personal` and `us-east-1`.

The CLI makes a private bucket, uploads a one-field page, prints its link
once, waits for the upload, validates it, stages it in the cf secret store,
and deletes the bucket on every exit path. The link is for the user only;
do not forward it. Exit codes: 0 staged, 1 usage, 3 empty or failed
validation, 4 no upload before the link expired, 5 AWS failure (if teardown
fails, the output names the manual delete command), 130 interrupted.

## See what is staged

```
ruby ~/.claude/cf/bin/secret_intake.rb status
```

Names, ages and validation only, never a value. Staged secrets stay until
removed.

Where a staged secret goes next is the user's call: ask with the
`Secret destination` question header, which away mode still lets through.

## Push a staged secret

```
ruby ~/.claude/cf/bin/secret_intake.rb push NAME --to env:.env.local
ruby ~/.claude/cf/bin/secret_intake.rb push NAME --to cf-key:openai [--dir PATH]
ruby ~/.claude/cf/bin/secret_intake.rb push NAME --to ssm:/app/prod/NAME \
  --profile personal --region us-east-1 --confirm-account <id> [--overwrite]
ruby ~/.claude/cf/bin/secret_intake.rb remove NAME
```

`env:` sets `NAME=` in the file (relative to the current directory), keeps a
`.bak`, and appends the file to the repo `.gitignore` when git does not
already ignore it. `cf-key:` enrolls the value as that provider's key at
`--dir` (default this project), validating it first unless intake already did.
`ssm:` writes a SecureString and prints the live account id, alias and path.

Before any `ssm:` push, ask the user with AskUserQuestion to confirm the
account id the push will write to, and pass `--confirm-account` only with the
id they confirmed. Without it, or with any other id, the push refuses before
writing. An existing parameter is refused unless the user asked for
`--overwrite`. Exit codes: 0 pushed, 1 usage or nothing staged, 3 provider
rejected the key, 5 AWS or write failure, 6 refused (account or overwrite).

## Env files are off limits to the agent

`secrets_read_guard.rb` denies agent file tools (Read, Edit, Write, Grep,
Glob) on any `.env` or `.env.<suffix>` file, a symlink to one included, and
any shell command that names one (`cat`, `source`, `grep`, `--env-file=`).
`.env.example`, `.env.sample` and `.env.template` stay readable, and so do
lookalikes such as `.envrc`. A bare run of `secret_intake.rb` is exempt, so
`push NAME --to env:.env.local` works; the same command piped, redirected or
chained is denied. To change a value, ask the user to edit the file, or stage
it here and push it.

Blast radius: this guard ships with the toolkit, so every project where cf is
installed loses agent reads of `.env` files, not just projects that use
intake. The user edits those files or runs `push`. It is a loud guardrail,
not a sandbox: a script that opens the file without naming it gets through.

## Risks

- The page link carries a short-lived session token. It is for the user
  only; never forward it, post it, or paste it into a PR or issue.
- The bucket is upload only. The page can PUT the one object and offers no
  read path; the CLI reads it back with the user's own credentials.
- Intake relies on the user's AWS SSO session lasting the TTL. The TTL is
  capped at the session's own expiry, and a session that ends early means
  no upload lands and intake exits 4.
- Teardown runs on every exit path short of kill -9. After a kill -9 the
  bucket's one-day expiry rule removes the object; the empty
  `<project>-key-intake-<hex>` bucket stays until deleted by hand.
