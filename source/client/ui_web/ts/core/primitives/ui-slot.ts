interface SlotOptions {
  className?: string;
  label?: string;
}
export function UiSlot(
  options: SlotOptions & { tag: 'button' },
): HTMLButtonElement;
export function UiSlot(options?: SlotOptions & { tag?: 'div' }): HTMLDivElement;
// A visual slot only. Size, item footprint and enabled actions belong to callers.
export function UiSlot({
  tag = 'div',
  className = '',
  label = '',
}: SlotOptions & { tag?: 'div' | 'button' } = {}) {
  const element = document.createElement(tag);
  element.className = 'ui-slot ' + className;
  if (label) element.setAttribute('aria-label', label);
  if (element instanceof HTMLButtonElement) element.type = 'button';
  return element;
}
