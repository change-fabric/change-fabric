import type { ReactNode } from "react";
import { Layout } from "../components/Layout";
import { CodeBlock } from "../components/CodeBlock";
import { Mark } from "../components/Logo";
import { Faux3Mark } from "../components/Faux3Mark";

const FAUX3_REPO_URL = "https://github.com/change-fabric/faux3";
const README_URL = `${FAUX3_REPO_URL}#readme`;
const ROADMAP_URL = `${FAUX3_REPO_URL}/blob/main/ROADMAP.md`;
const RELEASE_URL = `${FAUX3_REPO_URL}/releases/tag/v0.1.0`;
const CHANGELOG_URL = `${FAUX3_REPO_URL}/blob/main/CHANGELOG.md`;
const COMPAT_URL = `${FAUX3_REPO_URL}/blob/main/docs/compatibility.md`;
const TESTS_URL = `${FAUX3_REPO_URL}/tree/main/test/integration`;

// The nine S3 operations faux3 answers, grouped like the homepage lanes.
const OPERATIONS = [
  {
    n: "01",
    name: "Buckets",
    ops: ["CreateBucket", "ListBuckets", "HeadBucket", "DeleteBucket"],
  },
  {
    n: "02",
    name: "Objects",
    ops: ["PutObject", "GetObject", "HeadObject", "DeleteObject"],
  },
  { n: "03", name: "Listing", ops: ["ListObjectsV2"] },
];

// What faux3 does beyond the operations themselves.
const SCOPE = [
  "AWS SigV4 auth with static credentials",
  "Presigned GET and PUT URLs",
  "Filesystem persistence on a Docker volume",
  "linux/amd64 and linux/arm64 images",
];
// The install command for v0.1.0. The port binds to loopback only.
const RUN = `docker run -d --name faux3 \\
  -p 127.0.0.1:9000:9000 \\
  -v faux3-data:/data \\
  ghcr.io/change-fabric/faux3:0.1.0
`;

const SERVER_ENV = `FAUX3_ACCESS_KEY_ID=faux3
FAUX3_SECRET_ACCESS_KEY=faux3
FAUX3_REGION=us-east-1
FAUX3_PORT=9000
FAUX3_DATA_DIR=/data
# FAUX3_CORS_ORIGINS is off unless set
`;

// AWS CLI v2 has no environment variable for path-style addressing, so the
// example writes a small config file first, as the faux3 README does.
const CLI = `mkdir -p ~/.aws
cat > ~/.aws/faux3-config <<'EOF'
[default]
region = us-east-1
s3 =
  addressing_style = path
EOF
export AWS_CONFIG_FILE=~/.aws/faux3-config
export AWS_ENDPOINT_URL=http://localhost:9000
export AWS_ACCESS_KEY_ID=faux3
export AWS_SECRET_ACCESS_KEY=faux3

aws s3 mb s3://demo
echo hello > hello.txt
aws s3 cp hello.txt s3://demo/
aws s3 cp s3://demo/hello.txt -
# prints: hello
`;

const JS = `import {
  S3Client,
  CreateBucketCommand,
  PutObjectCommand,
  GetObjectCommand,
} from "@aws-sdk/client-s3";

const s3 = new S3Client({
  endpoint: "http://localhost:9000",
  region: "us-east-1",
  forcePathStyle: true,
  credentials: {
    accessKeyId: "faux3",
    secretAccessKey: "faux3",
  },
});

const Bucket = "demo-js";
const Key = "hello.txt";
await s3.send(
  new CreateBucketCommand({ Bucket }));
await s3.send(new PutObjectCommand(
  { Bucket, Key, Body: "hello" }));
const res = await s3.send(
  new GetObjectCommand({ Bucket, Key }));
console.log(
  await res.Body.transformToString());
// prints: hello
`;

function External({ href, children, className }: { href: string; children: ReactNode; className?: string }) {
  return (
    <a className={className} href={href} target="_blank" rel="noopener noreferrer">
      {children}
      <span className="sr-only"> (opens in a new tab)</span>
    </a>
  );
}

function TechMark({ id, name }: { id: string; name: string }) {
  return <span className={`tech-mark tech-${id}`} role="img" aria-label={name} />;
}

export function Faux3() {
  return (
    <Layout>
      <div className="home project faux3">
        <section className="hero project-hero" aria-labelledby="faux3-title">
          <p className="hero-eyebrow">
            Related project / Open source{" "}
            <External className="status-tag" href={RELEASE_URL}>
              v0.1.0
            </External>
          </p>
          <div className="project-hero-head">
            <Faux3Mark size={96} label="faux3 logo" />
            <h1 id="faux3-title">S3 without the cloud.</h1>
          </div>
          <p className="hero-copy">
            One container. One volume. One S3 endpoint. No AWS required. faux3 is a lightweight, open-source, S3-compatible object storage server for local
            development with Docker. Point the AWS SDK or AWS CLI you already use at it by changing the
            endpoint and credentials and turning on path-style addressing.
          </p>
          <p className="project-meta">MIT licensed · Local development · One Docker container</p>
          <ul className="project-status" aria-label="Release status">
            <li>
              <External href={RELEASE_URL}>v0.1.0</External>, released 10 Nov 2026
            </li>
            <li>Pre-alpha, 0.x</li>
            <li>
              <External href={CHANGELOG_URL}>Changelog</External>
            </li>
            <li>
              <External href={TESTS_URL}>Integration tests</External>
            </li>
          </ul>
          <div className="hero-actions">
            <a className="btn" href="#get-started">
              Get started <span aria-hidden="true">&rarr;</span>
            </a>
            <External className="btn btn-quiet" href={FAUX3_REPO_URL}>
              View on GitHub
            </External>
          </div>
        </section>

        <section className="home-section" aria-labelledby="faux3-arch-title">
          <h2 id="faux3-arch-title">The simplest way to run S3 locally.</h2>
          <p className="home-lede">
            Your app keeps its S3 client. faux3 answers on localhost, checks SigV4 signatures against
            static credentials and writes objects to a Docker volume, so nothing leaves your machine.
          </p>
          <div className="project-arch faux3-arch" role="group" aria-label="How a request flows">
            <div className="project-region">
              <p className="project-region-label">
                <TechMark id="docker" name="Docker" /> Your machine
              </p>
              <div className="project-node">
                <span className="project-node-title">Your app</span>
                <span className="project-node-sub">AWS SDK for JavaScript v3 or AWS CLI v2</span>
              </div>
              <p className="project-link">
                <span className="project-link-label">S3 API · SigV4</span>
                <span className="project-link-arrow" aria-hidden="true" />
              </p>
              <div className="project-hub">
                <Faux3Mark size={56} />
                <span className="project-hub-title">faux3</span>
                <span className="project-hub-sub">One container on port 9000</span>
              </div>
              <p className="project-link">
                <span className="project-link-label">Writes to</span>
                <span className="project-link-arrow" aria-hidden="true" />
              </p>
              <div className="project-node">
                <span className="project-node-title">A Docker volume</span>
                <span className="project-node-sub">Plain files under /data</span>
              </div>
            </div>
          </div>
          <p className="home-note project-arch-note">Written in Go, stdlib only · Distroless image</p>
        </section>

        <section className="home-section" aria-labelledby="faux3-ops-title">
          <h2 id="faux3-ops-title">Nine operations. Nothing more.</h2>
          <ul className="project-cards">
            {OPERATIONS.map((o) => (
              <li key={o.name}>
                <span className="lane-n" aria-hidden="true">{o.n}</span>
                <h3>{o.name}</h3>
                <p>
                  {o.ops.map((op, i) => (
                    <span key={op}>
                      {i > 0 ? ", " : ""}
                      <code>{op}</code>
                    </span>
                  ))}
                </p>
              </li>
            ))}
          </ul>
          <ul className="project-links faux3-scope" aria-label="Also in the first release">
            {SCOPE.map((s) => (
              <li key={s}>{s}</li>
            ))}
          </ul>
          <div className="faux3-boundary">
            <h3>Where it stops</h3>
            <p>
              Tested with AWS CLI v2 (2.39.7) and the AWS SDK for JavaScript v3 (3.1165.0).
              Path-style addressing only. No multipart upload, DeleteObjects or CopyObject, so
              uploads over the CLI's multipart threshold, <code>aws s3 mv</code> and{" "}
              <code>aws s3 rm --recursive</code> fail. No IAM, bucket policies, versioning or
              encryption. Local development only, never production. Details are in{" "}
              <External href={COMPAT_URL}>docs/compatibility.md</External>.
            </p>
          </div>
        </section>

        <section className="home-section" id="get-started" aria-labelledby="faux3-start-title">
          <h2 id="faux3-start-title">Get up and running.</h2>
          <p className="home-lede">
            You need Docker. faux3 is ready to use for local development.
          </p>
          <ol className="project-steps">
            <li>
              <h3>Run the container</h3>
              <p>
                One container, one named volume for your data. The port binds to 127.0.0.1, so
                only your machine reaches it. Run as a Compose service, faux3 answers other services at{" "}
                <code>http://faux3:9000</code> with no published port.
              </p>
              <div className="project-code">
                <CodeBlock code={RUN} label="install" />
              </div>
            </li>
            <li>
              <h3>Configure the server, if you need to</h3>
              <p>The defaults. CORS stays off unless you set allowed origins.</p>
              <div className="project-code">
                <CodeBlock code={SERVER_ENV} label="server defaults" />
              </div>
            </li>
            <li>
              <h3>Point the AWS CLI at it</h3>
              <p>
                Set the endpoint and credentials, and turn on path-style addressing in a config
                file. The last command prints <code>hello</code>.
              </p>
              <div className="project-code">
                <CodeBlock code={CLI} label="AWS CLI v2" />
              </div>
            </li>
            <li>
              <h3>Or from JavaScript</h3>
              <p>
                Pass the endpoint, region and credentials, and set <code>forcePathStyle: true</code>.
                Without it the SDK puts the bucket in the host name, which does not resolve.
              </p>
              <div className="project-code">
                <CodeBlock code={JS} label="AWS SDK for JavaScript v3" />
              </div>
            </li>
          </ol>
          <p className="home-note">
            See the <External href={README_URL}>README</External> for every setting and client
            example.
          </p>
        </section>

        <aside className="home-section project-roadmap" aria-labelledby="faux3-roadmap-title">
          <p className="hero-eyebrow">
            <span className="status-tag">Not another MinIO</span>
          </p>
          <h2 id="faux3-roadmap-title">Small on purpose</h2>
          <p className="home-lede">
            faux3 is a local development stand-in for S3, not production hosting. It leaves out
            multipart uploads (on the roadmap), IAM and bucket policies, versioning, encryption, a web
            UI and distributed storage.
          </p>
          <p className="home-lede">
            Want to help? <External href={ROADMAP_URL}>ROADMAP.md</External> lists the next
            operations, such as DeleteObjects, CopyObject, ListObjects V1 and multipart. Each one is a
            GitHub issue labelled good first issue.
          </p>
        </aside>

        <section className="home-section" aria-labelledby="faux3-family-title">
          <h2 id="faux3-family-title">Independent projects. Shared philosophy.</h2>
          <div className="project-family">
            <div>
              <p className="home-lede">
                faux3 is a separate, MIT-licensed project, not part of the Change Fabric spec. It is
                built with the Change Fabric cf skills (cf:plan and cf:diagram), and like the rest of
                the framework it is local-first and runs in containers.
              </p>
              <ul className="project-links" aria-label="faux3 resources">
                <li>
                  <External href={FAUX3_REPO_URL}>GitHub</External>
                </li>
                <li>
                  <External href={README_URL}>Documentation</External>
                </li>
                <li>
                  <External href={`${FAUX3_REPO_URL}/blob/main/LICENSE`}>License (MIT)</External>
                </li>
                <li>
                  <a href="/">About Change Fabric <span aria-hidden="true">&rarr;</span></a>
                </li>
              </ul>
            </div>
            <ul className="project-pair">
              <li>
                <Faux3Mark size={48} />
                <span className="project-pair-name">faux3</span>
                <span className="project-pair-sub">S3 on your machine</span>
              </li>
              <li>
                <Mark size={48} />
                <span className="project-pair-name">change fabric</span>
                <span className="project-pair-sub">Quality before merge</span>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </Layout>
  );
}
