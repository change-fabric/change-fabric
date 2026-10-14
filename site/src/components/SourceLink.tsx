import { GithubLogo } from "../icons";

// A quiet external link to source on GitHub, for reference page headers.
export function SourceLink({ href, label, title }: { href: string; label: string; title: string }) {
  return (
    <a className="btn btn-quiet source-link" href={href} target="_blank" rel="noopener noreferrer" title={title}>
      <GithubLogo size={14} />
      {label}
      <span className="sr-only">: {title} (opens in a new tab)</span>
    </a>
  );
}
