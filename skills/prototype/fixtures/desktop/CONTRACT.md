# Desktop kit contract (v1)

A neutral, unbranded desktop for `kind: "environment"` walkthrough scenes. It looks like no real operating system. Windows-style paths and `.bat` names are fine as text.

## Ownership

- The kit owns the chrome, the window manager (`wm.js`), the templates, and every fixed id below.
- The project owns the content: the seed (`store.seed`, shape in `desktop.schema.json`) and any page shown inside a browser window (`environment.slots`).

## Files

- `VERSION`: the kit version. It feeds every environment scene's `frames_key`, so a kit change recaptures.
- `desktop.css`: chrome styles. Colors and type read the project's `tokens.css` variables (`--bg`, `--surface`, `--surface-muted`, `--text`, `--muted`, `--border`, `--accent`, `--on-accent`, `--success`, `--font-sans`, `--font-mono`, `--radius`), the same names the message templates read, with neutral fallbacks.
- `wm.js`: open, focus, z-order, minimize, close; extract progress; download bar; editor dirty and saved state; terminal pacing. Every delay is a `setTimeout`, which the capture clock owns. Nothing reads the wall clock.
- `templates/*.html`: one per window type plus the page.

## Window types and fixed ids

Every window: `#win-<id>`, `#win-<id>-title`, `#win-<id>-min`, `#win-<id>-close`, and a taskbar button `#task-<id>`. The page: `#desktop`, `#taskbar`, `#taskbar-clock`.

- `browser`: `#<id>-tab`, `#<id>-address`, `#<id>-content` (the `data-cf-slot="<id>-content"` slot), `#<id>-download-bar`, `#<id>-download-<name>`, `#<id>-downloads`. A click on any element carrying `data-cfd-download="<name>"` inside the window starts that pending download.
- `file-explorer`: `#<id>-tree`, `#<id>-path`, `#<id>-files` with rows `#<id>-file-<name>`; with `extract_to`, `#<id>-extract` (Extract all), `#<id>-progress`, and the extracted rows `#<id>-xfile-<name>`. `opens` maps a file name to the window a double-click opens.
- `text-editor`: `#<id>-text` (type into it; Control+S saves), `#<id>-file`, `#<id>-saved`. A document's `caret_after` puts the caret right after that text on first focus.
- `terminal`: `#<id>-lines` with `#<id>-line-<n>`. Lines appear when the window opens, each `after_ms` after the previous one. A line with `service` and `status` updates that services row and brings its window to the front.
- `elevation-prompt`: `#<id>-question`, `#<id>-app`, `#<id>-publisher`, `#<id>-yes`, `#<id>-no`. Yes closes the prompt and opens `then`.
- `services-list`: `#<id>-table` with rows `#<id>-svc-<name>` and status cells `#<id>-svc-<name>-status`.

`<name>` is the lowercased name with every run of other characters turned into `-` (`config.json` becomes `config-json`).

## Generation and drift

`ruby scripts/walkthrough_environment.rb walkthrough/<slug>/storyboard.json` writes each environment scene's `screen.html`. Storyboard validation fails when a screen's ids differ from what the kit would write (drift), and when the file is merely stale. Edit the scene or the seed, never the generated file.
