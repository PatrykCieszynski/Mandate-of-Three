import type { ItemPresentation } from '../item-types.js';
import { UiTooltip } from '../../core/primitives/ui-tooltip.js';
import { itemRarity } from './item-tooltip-model.js';
export type ItemTooltipPresentation = Pick<
  ItemPresentation,
  'name' | 'description' | 'tooltip'
> &
  ({ kind?: 'item' } | { kind: 'shop-offer'; price: number; currency: 'yang' });
const detailsEvent = 'item-tooltip-details';
// Native input and browser input converge here without taking gameplay focus.
export function setItemTooltipDetails(
  doc: Document,
  alt: boolean,
  source: 'browser' | 'native' = 'browser',
) {
  if (source === 'native')
    doc.documentElement.dataset.nativeTooltipDetails = 'true';
  const value = String(alt);
  if (doc.documentElement.dataset.tooltipDetails === value) return;
  doc.documentElement.dataset.tooltipDetails = value;
  const EventConstructor = doc.defaultView?.Event;
  if (EventConstructor) doc.dispatchEvent(new EventConstructor(detailsEvent));
}
// Game UI owns item/offer meaning; core only positions supplied content.
export function ItemTooltip(
  root: HTMLElement,
  options: Parameters<typeof UiTooltip>[1],
) {
  const tooltip = UiTooltip(root, { ...options, aboveWindows: true }),
    doc = root.ownerDocument;
  tooltip.element.classList.add('item-tooltip');
  const title = doc.createElement('h2'),
    category = doc.createElement('p'),
    properties = doc.createElement('section'),
    requirements = doc.createElement('section'),
    affixes = doc.createElement('section'),
    description = doc.createElement('p'),
    price = doc.createElement('footer');
  title.className = 'item-tooltip-title';
  category.className = 'item-tooltip-category';
  properties.className = 'item-tooltip-properties';
  requirements.className = 'item-tooltip-requirements';
  affixes.className = 'item-tooltip-affixes';
  description.className = 'item-tooltip-description';
  price.className = 'item-tooltip-price';
  tooltip.contentRoot.append(
    title,
    category,
    properties,
    requirements,
    affixes,
    description,
    price,
  );
  let anchor = { x: 0, y: 0 },
    disposed = false;
  const labels: HTMLElement[] = [];
  function renderLines(section: HTMLElement, lines: readonly string[] = []) {
    section.replaceChildren(
      ...lines.map((text) => {
        const line = doc.createElement('p');
        line.textContent = text;
        return line;
      }),
    );
    section.hidden = lines.length === 0;
  }
  function refreshDetails() {
    const expanded = doc.documentElement.dataset.tooltipDetails === 'true';
    labels.forEach((label) => {
      label.hidden = !expanded;
    });
    if (!tooltip.element.hidden && !root.hidden && !disposed)
      tooltip.showAt(anchor);
  }
  function hide() {
    tooltip.hide();
  }
  function key(event: KeyboardEvent) {
    if (event.key === 'Alt')
      setItemTooltipDetails(doc, event.type === 'keydown');
  }
  function blur() {
    setItemTooltipDetails(doc, false);
    hide();
  }
  function visibility() {
    if (doc.hidden) blur();
  }
  doc.addEventListener('keydown', key);
  doc.addEventListener('keyup', key);
  doc.addEventListener(detailsEvent, refreshDetails);
  doc.addEventListener('visibilitychange', visibility);
  doc.defaultView?.addEventListener('blur', blur);
  return {
    element: tooltip.element,
    hide,
    show(
      event: Pick<MouseEvent, 'clientX' | 'clientY'> &
        Partial<Pick<MouseEvent, 'altKey'>>,
      item: ItemTooltipPresentation,
    ) {
      if (disposed || root.hidden) return;
      if (
        event.altKey !== undefined &&
        doc.documentElement.dataset.nativeTooltipDetails !== 'true'
      )
        setItemTooltipDetails(doc, event.altKey);
      const model = item.tooltip;
      title.textContent = item.name;
      tooltip.element.dataset.rarity = itemRarity(model?.affixes?.length ?? 0);
      category.textContent = model?.category ?? '';
      category.hidden = !model?.category;
      renderLines(properties, model?.properties);
      renderLines(requirements, model?.requirements);
      labels.length = 0;
      affixes.replaceChildren();
      // Keep supplied order; Alt reveals metadata without moving bonus lines.
      for (const affix of model?.affixes ?? []) {
        const block = doc.createElement('div'),
          label = doc.createElement('small');
        block.className = 'item-tooltip-affix';
        renderLines(block, affix.lines);
        label.className = 'item-tooltip-affix-kind';
        label.textContent = affix.kind === 'prefix' ? 'Prefix' : 'Suffix';
        if (affix.kind) {
          block.append(label);
          labels.push(label);
        }
        affixes.append(block);
      }
      affixes.hidden = !model?.affixes?.length;
      description.textContent = item.description ?? '';
      description.hidden = !item.description;
      price.hidden = item.kind !== 'shop-offer';
      price.textContent =
        item.kind === 'shop-offer'
          ? `Buy price: ${item.price.toLocaleString('en-US')} Yang`
          : '';
      const { scale } = options.geometry();
      anchor = { x: event.clientX / scale, y: event.clientY / scale };
      refreshDetails();
      tooltip.showAt(anchor);
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      doc.removeEventListener('keydown', key);
      doc.removeEventListener('keyup', key);
      doc.removeEventListener(detailsEvent, refreshDetails);
      doc.removeEventListener('visibilitychange', visibility);
      doc.defaultView?.removeEventListener('blur', blur);
      labels.length = 0;
      tooltip.dispose();
    },
  };
}
