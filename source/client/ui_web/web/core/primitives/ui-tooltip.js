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
export function UiTooltip(root, { geometry, aboveWindows = false, }) {
    const element = document.createElement('aside');
    element.className = 'ui-tooltip';
    element.hidden = true;
    root.append(element);
    // Manual popover uses the browser top layer, escaping window stacking contexts.
    // No focus, dismissal or modal behaviour; older hosts retain ordinary positioning.
    const topLayer = aboveWindows && typeof element.showPopover === 'function';
    if (topLayer)
        element.setAttribute('popover', 'manual');
    function hide() {
        element.hidden = true;
        if (topLayer && element.matches(':popover-open'))
            element.hidePopover();
    }
    const Observer = root.ownerDocument.defaultView?.MutationObserver;
    const visibility = topLayer && Observer
        ? new Observer(() => {
            if (root.hidden)
                hide();
        })
        : null;
    visibility?.observe(root, { attributes: true, attributeFilter: ['hidden'] });
    return {
        element,
        contentRoot: element,
        hide,
        showAt(point) {
            element.hidden = false;
            const { viewport, scale } = geometry();
            if (topLayer) {
                element.style.setProperty('--tooltip-scale', String(scale));
                if (!element.matches(':popover-open'))
                    element.showPopover();
            }
            const position = tooltipPosition(point, { width: element.offsetWidth, height: element.offsetHeight }, viewport, scale);
            element.style.left = position.x * (topLayer ? scale : 1) + 'px';
            element.style.top = position.y * (topLayer ? scale : 1) + 'px';
        },
        dispose() {
            visibility?.disconnect();
            hide();
            element.remove();
        },
    };
}
