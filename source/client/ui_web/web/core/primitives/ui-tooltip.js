export function tooltipPosition(point, size, viewport, scale, gap = 14) {
    const width = viewport.width / scale, height = viewport.height / scale;
    const left = point.x + gap + size.width > width
        ? point.x - size.width - gap
        : point.x + gap;
    return {
        x: Math.max(0, Math.min(left, width - size.width)),
        y: Math.max(0, Math.min(point.y + gap, height - size.height)),
    };
}
// Generic content and a logical anchor. The caller owns the meaning of the content.
export function UiTooltip(root, { geometry }) {
    const element = document.createElement('aside');
    element.className = 'ui-tooltip';
    element.hidden = true;
    root.append(element);
    return {
        element,
        contentRoot: element,
        hide() {
            element.hidden = true;
        },
        showAt(point) {
            element.hidden = false;
            const { viewport, scale } = geometry();
            const position = tooltipPosition(point, { width: element.offsetWidth, height: element.offsetHeight }, viewport, scale);
            element.style.left = position.x + 'px';
            element.style.top = position.y + 'px';
        },
        dispose() {
            element.remove();
        },
    };
}
