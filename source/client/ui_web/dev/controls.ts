import type { PreviewAction } from './contracts.js';
const frame = document.querySelector('iframe');
const log = document.querySelector('pre');
const status = document.querySelector('#status');
if (!frame || !log || !status) throw Error('Missing preview controls');
function send(action: PreviewAction) {
  frame?.contentWindow?.postMessage(action, location.origin);
}
for (const button of document.querySelectorAll<HTMLButtonElement>(
  'button[data-action]',
)) {
  button.addEventListener('click', () => {
    const action = button.dataset.action;
    if (action === 'reset' || action === 'empty' || action === 'escape') {
      if (action === 'reset') {
        const scale = document.querySelector<HTMLSelectElement>('#scale');
        if (scale) scale.value = '1';
      }
      send({ action });
    } else if (
      action === 'inventory' ||
      action === 'equipment' ||
      action === 'storage'
    )
      send({ action, value: button.dataset.value === 'true' });
  });
}
document.querySelector('#scale')?.addEventListener('change', (event) => {
  if (event.target instanceof HTMLSelectElement)
    send({ action: 'scale', value: Number(event.target.value) });
});
document.querySelector('#accept')?.addEventListener('change', (event) => {
  if (event.target instanceof HTMLInputElement)
    send({ action: 'accept', value: event.target.checked });
});
document
  .querySelector('#wallet')
  ?.addEventListener('click', () => send({ action: 'wallet', value: 54321 }));
document.querySelector('#clear')?.addEventListener('click', () => {
  log.textContent = '';
});
window.addEventListener('message', (event) => {
  if (event.source !== frame.contentWindow || event.origin !== location.origin)
    return;
  const data: unknown = event.data;
  if (
    data === null ||
    typeof data !== 'object' ||
    !('source' in data) ||
    data.source !== 'mandate-ui-preview'
  )
    return;
  if ('ready' in data && data.ready === true) {
    status.textContent = 'Ready — production UI with fixture IPC';
    document
      .querySelectorAll<
        HTMLButtonElement | HTMLInputElement | HTMLSelectElement
      >('button,input,select')
      .forEach((control) => (control.disabled = false));
    const scale = document.querySelector<HTMLSelectElement>('#scale');
    if (scale) send({ action: 'scale', value: Number(scale.value) });
    const accept = document.querySelector<HTMLInputElement>('#accept');
    if (accept) send({ action: 'accept', value: accept.checked });
  }
  if ('message' in data)
    log.textContent = (
      JSON.stringify(data.message) +
      '\n' +
      (log.textContent ?? '')
    ).slice(0, 12000);
});
