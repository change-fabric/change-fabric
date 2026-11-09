import { useEffect, useRef, useState } from "react";
import manifest from "../generated/media.json";
import { activeWordIndex, formatDuration, type MediaEntry, type Word } from "../media";

const SLOTS = (manifest as { slots: Record<string, MediaEntry> }).slots;

function prefersReducedMotion(): boolean {
  return typeof window.matchMedia === "function" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

// One click-to-load media slot. Before the click there is no <video> or
// <audio> in the DOM, so the page fetches no media bytes; the click swaps in
// the player with captions on, plays it, and moves focus to it. A slot with no
// manifest entry renders nothing; one whose bytes are missing (a fresh clone,
// a preview) says so and keeps its transcript.
export function MediaSlot({ slot }: { slot: string }) {
  const entry = SLOTS[slot];
  if (!entry) return null;
  return <MediaFigure entry={entry} />;
}

function MediaFigure({ entry }: { entry: MediaEntry }) {
  const [started, setStarted] = useState(false);
  const [unavailable, setUnavailable] = useState(false);
  const [words, setWords] = useState<Word[] | null>(null);
  const [active, setActive] = useState(-1);
  const mediaRef = useRef<HTMLVideoElement & HTMLAudioElement>(null);
  const duration = formatDuration(entry.duration_ms);
  const noun = entry.kind === "video" ? "Video" : "Audio";

  useEffect(() => {
    const media = mediaRef.current;
    if (!started || !media) return;
    media.focus();
    media.play().catch(() => setUnavailable(true));
  }, [started]);

  // Words load only after the click, so they never cost a byte before it.
  useEffect(() => {
    if (!started || !entry.words) return;
    let cancelled = false;
    fetch(entry.words)
      .then((response) => (response.ok ? response.json() : null))
      .then((data) => {
        if (!cancelled && Array.isArray(data)) setWords(data as Word[]);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [started, entry.words]);

  // Follow-along highlight: only while playing, never under reduced motion.
  useEffect(() => {
    const media = mediaRef.current;
    if (!started || !media || !words || prefersReducedMotion()) return;
    let frame = 0;
    const tick = () => {
      setActive(activeWordIndex(words, media.currentTime * 1000));
      if (!media.paused && !media.ended) frame = requestAnimationFrame(tick);
    };
    const start = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(tick);
    };
    const stop = () => {
      cancelAnimationFrame(frame);
      setActive(-1);
    };
    media.addEventListener("play", start);
    media.addEventListener("timeupdate", tick);
    media.addEventListener("pause", stop);
    media.addEventListener("ended", stop);
    if (!media.paused) start();
    return () => {
      cancelAnimationFrame(frame);
      media.removeEventListener("play", start);
      media.removeEventListener("timeupdate", tick);
      media.removeEventListener("pause", stop);
      media.removeEventListener("ended", stop);
    };
  }, [started, words]);

  const sized = entry.width && entry.height ? { width: entry.width, height: entry.height } : {};
  const onError = () => setUnavailable(true);

  let player;
  if (!started) {
    player = (
      <div className="media-slot-cover">
        {entry.poster ? (
          <img src={entry.poster} alt={entry.alt} {...sized} loading="lazy" decoding="async" />
        ) : null}
        <span className="media-slot-duration" aria-hidden="true">
          {duration}
        </span>
        <button type="button" className="media-slot-play" onClick={() => setStarted(true)}>
          Play: {entry.title} ({duration})
        </button>
      </div>
    );
  } else if (entry.kind === "video") {
    player = (
      <video
        ref={mediaRef}
        controls
        preload="none"
        playsInline
        poster={entry.poster ?? undefined}
        aria-label={entry.title}
        onError={onError}
        {...sized}
      >
        <source src={entry.src} type="video/mp4" onError={onError} />
        <track kind="captions" srcLang="en" label="English" src={entry.vtt} default />
      </video>
    );
  } else {
    player = (
      <audio ref={mediaRef} controls preload="none" aria-label={entry.title} onError={onError}>
        <source src={entry.src} type="audio/mpeg" onError={onError} />
        <track kind="captions" srcLang="en" label="English" src={entry.vtt} default />
      </audio>
    );
  }

  return (
    <figure className={`media-slot media-slot-${entry.kind}`}>
      {player}
      {unavailable ? (
        <p className="media-slot-note" role="status">
          {noun} unavailable in this build
        </p>
      ) : null}
      <details className="media-slot-transcript">
        <summary>Transcript</summary>
        {words ? (
          <p>
            {words.map((word, index) => (
              <span key={index}>
                <span
                  className={index === active ? "media-word is-active" : "media-word"}
                  aria-current={index === active ? "true" : undefined}
                >
                  {word.text}
                </span>{" "}
              </span>
            ))}
          </p>
        ) : (
          <p>{entry.transcript}</p>
        )}
      </details>
    </figure>
  );
}
