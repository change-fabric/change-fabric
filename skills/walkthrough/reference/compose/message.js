// message template v1: the taps a simulated message responds to. Nothing is sent or received.
(() => {
  const on = (id, fn) => { const el = document.getElementById(id); if (el) el.addEventListener('click', fn); };
  on('banner', () => document.querySelector('.cfm-lock').classList.add('cfm-opening'));
  on('message', (ev) => ev.currentTarget.classList.add('cfm-picked'));
  on('cta', (ev) => ev.currentTarget.classList.add('cfm-pressed'));
  on('send', () => {
    const reply = document.getElementById('reply');
    if (!reply.value.trim()) return;
    const b = document.createElement('div'); b.className = 'cfm-out'; b.textContent = reply.value;
    document.getElementById('thread').appendChild(b);
    reply.value = '';
    document.getElementById('status').textContent = 'Delivered';
  });
})();
