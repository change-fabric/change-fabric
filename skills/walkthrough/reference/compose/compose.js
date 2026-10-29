// compose template v1: caret to the end on focus; Send shows the sent state.
document.querySelectorAll('input, textarea').forEach((el) => el.addEventListener('focus', () => {
  // Puts the caret after the prefilled text, as a real composer does.
  const n = el.value.length; el.setSelectionRange(n, n);
}));
document.getElementById('send').addEventListener('click', () => {
  const body = document.getElementById('body');
  const thread = document.querySelector('.thread');
  if (thread) {
    const b = document.createElement('div'); b.className = 'bubble'; b.textContent = body.value; thread.appendChild(b);
    body.value = '';
  }
  document.querySelectorAll('input, textarea').forEach((el) => { el.readOnly = true; });
  const send = document.getElementById('send'); send.disabled = true; send.textContent = 'Sent';
  document.getElementById('status').textContent = document.getElementById('status').dataset.sent || (thread ? 'Delivered' : 'Message sent');
});
