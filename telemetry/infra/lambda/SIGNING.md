# Ed25519 canonical-byte signing contracts

This file is the single authoritative source for the exact byte strings that are
Ed25519-signed on the client (pst-side hooks) and verified in the Lambdas. There
are **three distinct schemes**. The signing side and the verifying side must
produce **byte-identical** canonical bytes or every signature verification fails.

## Universal rules (apply to all three schemes)

- The canonical byte string is the listed fields, **in the exact order given**,
  **joined by a single newline `"\n"` (LF, 0x0A)**.
- **No trailing newline.** N fields produce exactly N-1 separators.
- Encoding is **UTF-8**.
- Every field is included **except `sig`**. `sig` is
  `base64(Ed25519_sign(team_private_key, canonical_bytes))`, sent alongside the
  payload.
- Each field value is its **plain string form** exactly as sent in the JSON
  payload (no JSON quoting, no escaping, no trimming). Timestamps are the ISO8601
  string; `chosen_option` is stringified (`"1"`, `"2"`, or `"3"`).
- The public key is base64 in `cf-teams.public_key_ed25519`; the signature is
  base64 in the payload's `sig`. Both are `Base64.decode64`'d before verify.
- Server-side also enforces: `ts` within `TS_SKEW_SECONDS` of now, and a fresh
  random `nonce` per request (uniqueness of signature, not stored/replay-checked
  in this POC).

---

## 1. Presence - 7 fields (`POST /presence`)

Verified in `presence/handler.rb`.

Field order:

```
team_id
contributor_id
contributor_name
repo_id
file_path
ts
nonce
```

Canonical bytes (Ruby, copy-pasteable, identical on both sides):

```ruby
canonical_bytes = [
  team_id,
  contributor_id,
  contributor_name,
  repo_id,
  file_path,
  ts,
  nonce
].join("\n").encode("UTF-8")
```

---

## 2. Notifications poll - 4 fields (`POST /notifications`)

Verified in `notifications/handler.rb` (`handle_poll`).

Field order:

```
team_id
contributor_id
ts
nonce
```

Canonical bytes:

```ruby
canonical_bytes = [
  team_id,
  contributor_id,
  ts,
  nonce
].join("\n").encode("UTF-8")
```

---

## 3. Notifications ack - 6 fields (`POST /notifications/ack`)

Verified in `notifications/handler.rb` (`handle_ack`).

Field order:

```
team_id
contributor_id
ts
nonce
finding_id
chosen_option
```

Canonical bytes:

```ruby
canonical_bytes = [
  team_id,
  contributor_id,
  ts,
  nonce,
  finding_id,
  chosen_option        # stringified "1" | "2" | "3"
].join("\n").encode("UTF-8")
```

---

## Signing reference (client side)

```ruby
require "ed25519"
require "base64"

signing_key = Ed25519::SigningKey.new(private_key_bytes) # from Keychain
sig = Base64.strict_encode64(signing_key.sign(canonical_bytes))
payload = base_fields.merge("sig" => sig)  # base_fields = every signed field
```

The transcript path (`POST /transcripts`) is **not** signed - it uses the
shared-secret `x-api-key` authorizer instead (plan section 5.1). Only presence,
the notifications poll, and the notifications ack are Ed25519-signed.
