# CF mode selection

Invoke `{{skill:cf}}` to select merge mode and availability using the host's
native question interface, or plain conversation if that interface is absent.

- `{{skill:local-only}}`: keep changes on disk; no push, new PR, or merge.
- `{{skill:merge-ready}}`: feature branch and green PR; stop before merging.
- `{{skill:admin-bypass}}`: green PR followed by an authorized squash admin merge.
- `{{skill:yolo}}`: push to the selected target branch; no new PR.
- `{{skill:active}}`: ask questions normally.
- `{{skill:away}}`: take safe defaults and report assumptions.

Acknowledge both choices. Persist through the installed adapter when available;
otherwise carry intent in conversation and compaction summaries. Never claim a
hook already wrote state. Availability never grants permission for destructive
operations, and merge mode never changes host permissions.
