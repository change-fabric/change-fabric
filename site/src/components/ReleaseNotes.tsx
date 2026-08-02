import { releaseNote } from "../releaseNotes";

// The "What's new" panel above a spec version's own text. Renders nothing at
// all for a version with no notes, so it is safe to mount unconditionally on
// every /spec/<version> page.
export function ReleaseNotes({ version }: { version: string }) {
  const note = releaseNote(version);

  if (note === undefined) {
    return null;
  }

  return (
    <section className="release-notes" data-testid={`release-notes-${note.version}`}>
      <h2>What is new in {note.version}</h2>
      <p className="release-notes-headline">{note.headline}</p>
      <dl className="release-notes-list">
        {note.highlights.map((highlight) => (
          <div className="release-note" key={highlight.title}>
            <dt>{highlight.title}</dt>
            <dd>{highlight.body}</dd>
          </div>
        ))}
      </dl>
      <p className="release-notes-upgrade">
        <strong>Upgrading:</strong> {note.upgrade}
      </p>
    </section>
  );
}
