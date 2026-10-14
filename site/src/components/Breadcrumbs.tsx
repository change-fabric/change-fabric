// The trail above a reference detail page's title: the index, then the
// group the entry is filed under, each a link back into the filtered index.
export function Breadcrumbs({ group, label }: { group: string; label: string }) {
  return (
    <nav className="breadcrumbs" aria-label="Breadcrumb">
      <ol>
        <li>
          <a href="/reference">Reference</a>
        </li>
        <li>
          <a href={`/reference?group=${group}`}>{label}</a>
        </li>
      </ol>
    </nav>
  );
}
