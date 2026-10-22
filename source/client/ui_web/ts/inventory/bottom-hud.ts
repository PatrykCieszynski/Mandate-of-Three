// Bottom world HUD. Bindings and executable actions remain server/client-domain responsibilities.
export function mountBottomHud(root: HTMLElement) {
  if (!(root instanceof HTMLElement)) throw Error('Missing bottom HUD root');
  const panel = document.createElement('div');
  panel.className = 'bottom-hud-panel';
  const slots = document.createElement('div');
  slots.className = 'bottom-hud-slots';
  const buttons: HTMLElement[] = [];
  for (let i = 0; i < 8; i++) {
    const slot = document.createElement('div');
    slot.className = 'bottom-hud-slot';
    slot.setAttribute('aria-label', `Quick slot ${i + 1}, empty`);
    const key = document.createElement('span');
    key.className = 'bottom-hud-key';
    key.textContent = String(i + 1);
    slot.append(key);
    buttons.push(slot);
    slots.append(slot);
  }
  panel.append(slots);
  root.append(panel);
  return {
    setScale(scale: number) {
      if (!Number.isFinite(scale) || scale <= 0)
        throw Error('Invalid UI scale');
      root.style.setProperty('--ui-scale', String(scale));
    },
    // Presentation-only until authenticated item/skill execution is available.
    render(bindings: readonly Readonly<{ label?: string }>[] = []) {
      buttons.forEach((slot, i) => {
        const binding = bindings[i];
        const name = typeof binding?.label === 'string' ? binding.label : '';
        slot.setAttribute(
          'aria-label',
          name ? `Quick slot ${i + 1}: ${name}` : `Quick slot ${i + 1}, empty`,
        );
        slot.classList.toggle('assigned', !!name);
        let text = slot.querySelector<HTMLElement>('.bottom-hud-item-name');
        if (!text && name) {
          text = document.createElement('span');
          text.className = 'bottom-hud-item-name';
          slot.append(text);
        }
        if (text) {
          text.textContent = name;
          text.hidden = !name;
        }
      });
    },
    dispose() {
      panel.remove();
    },
  };
}
