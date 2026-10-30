// cf desktop kit window manager. Deterministic: every delay runs through
// setTimeout, which the capture clock owns, and nothing reads the wall clock.
// The markup (fixed ids, data-cfd-* attributes) is written by
// scripts/walkthrough_environment.rb; this file only adds behavior.
(() => {
  const $ = (id) => document.getElementById(id);
  const wins = () => Array.from(document.querySelectorAll('.cfd-win'));
  const idOf = (win) => win.id.slice(4);
  let z = 10;

  const syncTask = (id) => {
    const task = $(`task-${id}`);
    const win = $(`win-${id}`);
    if (!task || !win) return;
    task.hidden = win.hidden;
    task.classList.toggle('cfd-focus', win.classList.contains('cfd-focus'));
  };

  const focus = (id) => {
    const win = $(`win-${id}`);
    if (!win || win.hidden) return;
    wins().forEach((w) => w.classList.remove('cfd-focus'));
    win.classList.remove('cfd-min');
    win.classList.add('cfd-focus');
    win.style.zIndex = String(++z);
    wins().forEach((w) => syncTask(idOf(w)));
  };

  const open = (id) => {
    const win = $(`win-${id}`);
    if (!win) return;
    const was = win.hidden;
    win.hidden = false;
    focus(id);
    if (was && win.dataset.cfdType === 'terminal') runTranscript(id);
  };

  const minimize = (id) => {
    const win = $(`win-${id}`);
    if (!win) return;
    win.classList.add('cfd-min');
    win.classList.remove('cfd-focus');
    syncTask(id);
  };

  const close = (id) => {
    const win = $(`win-${id}`);
    if (!win) return;
    win.hidden = true;
    win.classList.remove('cfd-focus');
    syncTask(id);
  };

  // Paced steps: fn(i) for i = 1..steps, one every ms.
  const steps = (count, ms, fn, done) => {
    let i = 0;
    const tick = () => { i += 1; fn(i); if (i < count) setTimeout(tick, ms); else if (done) done(); };
    setTimeout(tick, ms);
  };

  const setService = (slug, status) => {
    document.querySelectorAll(`[data-cfd-svc="${slug}"]`).forEach((cell) => {
      cell.textContent = status;
      cell.classList.toggle('cfd-running', status === 'Running');
    });
  };

  const runTranscript = (id) => {
    const lines = Array.from(document.querySelectorAll(`#${id}-lines > div`));
    let at = 0;
    lines.forEach((line) => {
      at += Number(line.dataset.after || 0);
      setTimeout(() => {
        line.hidden = false;
        if (line.dataset.cfdService) {
          setService(line.dataset.cfdService, line.dataset.cfdStatus);
          const row = document.querySelector(`[data-cfd-svc="${line.dataset.cfdService}"]`);
          const win = row && row.closest('.cfd-win');
          if (win && !win.hidden) focus(idOf(win));
        }
      }, Math.max(1, at));
    });
  };

  const extract = (id, button) => {
    const win = $(`win-${id}`);
    const bar = $(`${id}-progress`);
    button.disabled = true;
    bar.hidden = false;
    steps(10, 120, (i) => { bar.firstElementChild.style.width = `${i * 10}%`; }, () => {
      bar.hidden = true;
      $(`${id}-files`).hidden = true;
      $(`${id}-xfiles`).hidden = false;
      $(`${id}-path`).textContent = win.dataset.cfdExtractTo;
      document.querySelectorAll(`#${id}-tree li`).forEach((li) => li.classList.toggle('cfd-here', li.dataset.path === win.dataset.cfdExtractTo));
    });
  };

  const download = (winId, name) => {
    const bar = $(`${winId}-download-bar`);
    if (!bar) return;
    bar.hidden = false;
    document.querySelectorAll(`#${winId}-download-bar [data-cfd-dl]`).forEach((item) => {
      if (name && item.dataset.cfdDl !== name) return;
      item.hidden = false;
      const state = item.querySelector('.cfd-dl-state');
      steps(5, 200, (i) => { state.textContent = i < 5 ? `${i * 20}%` : 'Done'; });
    });
  };

  document.addEventListener('mousedown', (ev) => {
    const win = ev.target.closest('.cfd-win');
    if (win) focus(idOf(win));
  });

  document.addEventListener('click', (ev) => {
    const t = ev.target.closest('button, [data-cfd-download], .cfd-file');
    if (!t) return;
    const win = t.closest('.cfd-win');
    if (t.dataset.cfdMin) return minimize(t.dataset.cfdMin);
    if (t.dataset.cfdClose) return close(t.dataset.cfdClose);
    if (t.dataset.cfdTask) { const w = $(`win-${t.dataset.cfdTask}`); return w && w.classList.contains('cfd-focus') ? minimize(t.dataset.cfdTask) : focus(t.dataset.cfdTask); }
    if (t.dataset.cfdExtract) return extract(t.dataset.cfdExtract, t);
    if (t.dataset.cfdDownload !== undefined && win) { ev.preventDefault(); return download(idOf(win), t.dataset.cfdDownload); }
    if (t.dataset.cfdYes) { close(t.dataset.cfdYes); if (t.dataset.cfdThen) open(t.dataset.cfdThen); return; }
    if (t.dataset.cfdNo) return close(t.dataset.cfdNo);
    if (t.classList.contains('cfd-file')) {
      t.parentElement.querySelectorAll('.cfd-file').forEach((f) => f.classList.remove('cfd-picked'));
      t.classList.add('cfd-picked');
    }
  });

  document.addEventListener('dblclick', (ev) => {
    const t = ev.target.closest('[data-cfd-open]');
    if (t) open(t.dataset.cfdOpen);
  });

  // The first focus of an editor puts the caret right after its caret_after
  // text, so typed text lands where a person would paste it.
  // A click sets the caret itself after focus, so only a click (or a focus
  // that no click follows) marks the caret as placed.
  const placeCaret = (ev) => {
    const ed = ev.target.closest && ev.target.closest('.cfd-text');
    if (!ed || ed.dataset.cfdPlaced || !ed.dataset.cfdCaret) return;
    if (ev.type === 'click') ed.dataset.cfdPlaced = '1';
    const at = ed.value.indexOf(ed.dataset.cfdCaret);
    if (at >= 0) { const pos = at + ed.dataset.cfdCaret.length; ed.setSelectionRange(pos, pos); }
  };
  document.addEventListener('focusin', placeCaret);
  document.addEventListener('click', placeCaret);

  document.addEventListener('input', (ev) => {
    const ed = ev.target.closest('.cfd-text');
    if (!ed) return;
    const id = ed.dataset.cfdEditor;
    $(`${id}-saved`).textContent = 'Unsaved changes';
    $(`win-${id}-title`).textContent = `*${$(`win-${id}`).dataset.cfdName}`;
  });

  document.addEventListener('keydown', (ev) => {
    const ed = ev.target.closest && ev.target.closest('.cfd-text');
    if (!ed || !(ev.ctrlKey || ev.metaKey) || ev.key.toLowerCase() !== 's') return;
    ev.preventDefault();
    const id = ed.dataset.cfdEditor;
    $(`${id}-saved`).textContent = 'Saved';
    $(`win-${id}-title`).textContent = $(`win-${id}`).dataset.cfdName;
  });

  wins().forEach((w) => { if (!w.hidden && w.dataset.cfdType === 'terminal') runTranscript(idOf(w)); });
  const first = document.querySelector('.cfd-win.cfd-focus');
  if (first) focus(idOf(first));
  window.__cfDesktop = { open, focus, minimize, close };
})();
