import { UiTooltip } from '../../core/primitives/ui-tooltip.js';
// Item labels/descriptions stay in game UI; core only positions supplied content.
export function ItemTooltip(root, options) {
    const tooltip = UiTooltip(root, options);
    tooltip.element.classList.add('item-tooltip');
    const title = document.createElement('h2'), description = document.createElement('p');
    tooltip.contentRoot.append(title, description);
    return { element: tooltip.element, hide: tooltip.hide,
        show(event, item) {
            title.textContent = item.name;
            description.textContent = item.description ?? '';
            const { scale } = options.geometry();
            tooltip.showAt({ x: event.clientX / scale, y: event.clientY / scale });
        }, dispose: tooltip.dispose };
}
