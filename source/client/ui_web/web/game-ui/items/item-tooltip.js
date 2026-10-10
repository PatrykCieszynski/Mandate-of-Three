import { UiTooltip } from '../../core/primitives/ui-tooltip.js';
const currencyLabels = { yang: 'Yang' };
// Game UI owns item/offer meaning; core only positions supplied content.
export function ItemTooltip(root, options) {
    const tooltip = UiTooltip(root, options);
    tooltip.element.classList.add('item-tooltip');
    const title = document.createElement('h2'), description = document.createElement('p'), price = document.createElement('footer');
    price.className = 'item-tooltip-price';
    price.hidden = true;
    tooltip.contentRoot.append(title, description, price);
    return {
        element: tooltip.element,
        hide: tooltip.hide,
        show(event, item) {
            title.textContent = item.name;
            description.textContent = item.description ?? '';
            description.hidden = !item.description;
            price.hidden = item.kind !== 'shop-offer';
            price.textContent =
                item.kind === 'shop-offer'
                    ? `Buy price: ${item.price.toLocaleString('en-US')} ${currencyLabels[item.currency]}`
                    : '';
            const { scale } = options.geometry();
            tooltip.showAt({ x: event.clientX / scale, y: event.clientY / scale });
        },
        dispose: tooltip.dispose,
    };
}
