import { useEffect, useRef, useState } from "react";
import manifest from "../generated/media.json";
import { Mark } from "./Logo";
import { activeWordIndex, captionText, formatDuration, highlightLoop, type MediaEntry, type Word } from "../media";

const SLOTS = (manifest as { slots: Record<string, MediaEntry> }).slots;

function prefersReducedMotion(): boolean {
  return typeof window.matchMedia === "function" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

// One click-to-load media slot. Before the click the player has no src, so
// the page fetches no media bytes; the click gives it its src, plays it with
// captions on, and moves focus to it. A slot with no
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

  // Focus moves to the player once it is revealed: inside the click handler
  // the player is still hidden (React applies `started` after the handler
  // returns), so a focus() there is a no-op and focus would be lost with the
  // removed play button.
  useEffect(() => {
    if (started) mediaRef.current?.focus();
  }, [started]);

  // Follow-along highlight: only while playing, never under reduced motion.
  useEffect(() => {
    const media = mediaRef.current;
    if (!started || !media || !words || prefersReducedMotion()) return;
    const { start, stop, onTimeUpdate } = highlightLoop({
      playing: () => !media.paused && !media.ended,
      update: () => setActive(activeWordIndex(words, media.currentTime * 1000)),
      clear: () => setActive(-1),
      raf: (callback) => requestAnimationFrame(callback),
      cancel: (id) => cancelAnimationFrame(id),
    });
    media.addEventListener("play", start);
    media.addEventListener("timeupdate", onTimeUpdate);
    media.addEventListener("pause", stop);
    media.addEventListener("ended", stop);
    if (!media.paused) start();
    return () => {
      stop();
      media.removeEventListener("play", start);
      media.removeEventListener("timeupdate", onTimeUpdate);
      media.removeEventListener("pause", stop);
      media.removeEventListener("ended", stop);
    };
  }, [started, words]);

  const sized = entry.width && entry.height ? { width: entry.width, height: entry.height } : {};
  const onError = () => setUnavailable(true);

  // The player is in the DOM from the first render with no src and
  // preload="none", so it costs no bytes until the click. The click sets the
  // src and calls play() on that same element inside the tap: iOS Safari
  // honors play() only within the user gesture, and the earlier design (a
  // fresh <video> with <source> children swapped in, play() from an effect)
  // sat at 00:00 / 00:00 there and never loaded.
  const start = () => {
    const media = mediaRef.current;
    setStarted(true);
    if (!media) return;
    media.src = entry.src;
    media.play().catch((error: unknown) => {
      if (!(error instanceof DOMException && error.name === "AbortError")) setUnavailable(true);
    });
  };

  const icon = (
    <span className="media-slot-play-icon" aria-hidden="true">
      <svg viewBox="0 0 24 24" focusable="false">
        <path d="M8 5.5v13l10.5-6.5z" />
      </svg>
    </span>
  );
  // Captions mount with the click, so the .vtt is not fetched before it.
  const track = <track kind="captions" srcLang="en" label="English" src={entry.vtt} default />;

  const player =
    entry.kind === "video" ? (
      <div
        className="media-slot-frame"
        style={entry.width && entry.height ? { aspectRatio: `${entry.width} / ${entry.height}` } : undefined}
      >
        <video
          ref={mediaRef}
          controls={started}
          preload="none"
          playsInline
          poster={started ? (entry.poster ?? undefined) : undefined}
          aria-label={entry.title}
          aria-hidden={started ? undefined : true}
          tabIndex={started ? undefined : -1}
          onError={onError}
          {...sized}
        >
          {started ? track : null}
        </video>
        {started ? null : (
          // The designed thumbnail: the woven mark on a plum ground, the
          // poster crop over it under a scrim, then the title and play mark.
          // A missing poster leaves the mark and ground, never a blank block.
          // The runtime is only in the accessible name, not on screen. The
          // whole surface is one native button, so a click, a tap, Enter and
          // Space all reach start().
          <button type="button" className="media-slot-play media-slot-thumb" onClick={start}>
            <Mark size={96} className="media-slot-thumb-emblem" />
            {entry.poster ? (
              <img
                className="media-slot-thumb-image"
                src={entry.poster}
                alt=""
                {...sized}
                loading="lazy"
                decoding="async"
                onError={(event) => {
                  event.currentTarget.hidden = true;
                }}
              />
            ) : null}
            <span className="media-slot-thumb-scrim" aria-hidden="true" />
            <span className="media-slot-thumb-bar" aria-hidden="true">
              {icon}
              <span className="media-slot-thumb-title">
                <Mark size={20} />
                {entry.title}
              </span>
            </span>
            <span className="sr-only">
              Play video: {entry.title} ({duration})
            </span>
          </button>
        )}
      </div>
    ) : (
      <div className="media-slot-audio-row">
        {started ? null : (
          <button type="button" className="media-slot-play" onClick={start}>
            {icon}
            <span>
              Play: {entry.title} ({duration})
            </span>
          </button>
        )}
        <audio ref={mediaRef} controls hidden={!started} preload="none" aria-label={entry.title} onError={onError}>
          {started ? track : null}
        </audio>
      </div>
    );

  return (
    <figure className={`media-slot media-slot-${entry.kind}`}>
      {player}
      {entry.kind === "video" ? (
        <figcaption className="media-slot-caption">
          {captionText(entry)}
        </figcaption>
      ) : null}
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
