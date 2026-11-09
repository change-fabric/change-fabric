import { Layout } from "../components/Layout";
import { MediaSlot } from "../components/MediaSlot";

// Routed only in a VITE_MEDIA_FIXTURE=1 build, which verify/media.mjs makes:
// both slot kinds against the committed fixture bytes. A production build
// never reaches this module.
export function MediaFixture() {
  return (
    <Layout>
      <section className="media-fixture">
        <h1>Media slot fixture</h1>
        <h2>Video</h2>
        <MediaSlot slot="fixture-video" />
        <h2>Audio</h2>
        <MediaSlot slot="fixture-audio" />
      </section>
    </Layout>
  );
}
