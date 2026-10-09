import { UiWindow } from '../../core/window/ui-window.js';
import { UiTab } from '../../core/primitives/ui-tab.js';
import { UiItemGrid } from '../../game-ui/items/ui-item-grid.js';
import { UiItemSlot } from '../../game-ui/items/ui-item-slot.js';
import { ItemTooltip } from '../../game-ui/items/item-tooltip.js';
export function mountStorage(root, options) {
    const shell = new UiWindow(root, {
        id: 'storage',
        title: 'Storage',
        className: 'storage-window',
        manager: options.manager,
        placement: {
            kind: 'viewport',
            anchor: 'top-left',
            offset: { x: 16, y: 80 },
        },
        onClose: options.onClose,
        ...(options.onRegionsChanged
            ? { onRegionsChanged: options.onRegionsChanged }
            : {}),
        scrollBorder: 2,
        hideHorizontalOverflow: true,
        onCancel: () => tooltip.hide(),
    });
    const nav = document.createElement('nav');
    nav.className = 'storage-tabs';
    nav.setAttribute('aria-label', 'Storage pages');
    const gridRoot = document.createElement('div');
    gridRoot.className = 'storage-grid';
    const viewport = document.createElement('div');
    viewport.className = 'storage-grid-viewport';
    viewport.append(gridRoot);
    const capacity = document.createElement('p');
    capacity.className = 'storage-capacity';
    capacity.textContent = '135 slots per page · 2 pages';
    shell.contentRoot.append(nav, viewport, capacity);
    const grid = UiItemGrid(gridRoot, { slotSize: () => 40 });
    const tooltip = ItemTooltip(root, { geometry: () => options.manager });
    let state = { columns: 15, rows: 9, pages: 2, items: [] };
    let page = 0, disposed = false;
    const tabs = ['I', 'II'].map((label, index) => {
        const tab = UiTab({
            label,
            onSelect: () => {
                page = index;
                render();
            },
        });
        nav.append(tab.element);
        return tab;
    });
    function render() {
        tooltip.hide();
        grid.render({
            columns: state.columns,
            rows: state.rows,
            items: state.items.filter((item) => item.page === page),
        }, (item) => UiItemSlot({
            item,
            slotSize: 40,
            resolveItemIcon: options.resolveItemIcon,
        }));
        tabs.forEach((tab, index) => tab.setSelected(index === page));
        shell.refresh();
    }
    function itemFor(event) {
        const node = event.target instanceof Element
            ? event.target.closest('.ui-item-slot')
            : null;
        return state.items.find((item) => item.page === page && item.id === node?.dataset.id);
    }
    shell.listen(gridRoot, 'pointermove', (event) => {
        const item = itemFor(event);
        if (item && !shell.drag)
            tooltip.show(event, item);
        else
            tooltip.hide();
    });
    shell.listen(gridRoot, 'pointerleave', () => tooltip.hide());
    shell.listen(gridRoot, 'pointerdown', (event) => {
        const item = itemFor(event);
        if (item)
            options.onItemAction(event, item);
    });
    render();
    return {
        regions: [shell.panel],
        refresh: () => shell.refresh(),
        activate: () => shell.handle.activate(),
        setState(snapshot) {
            state = structuredClone(snapshot);
            render();
        },
        dispose() {
            if (disposed)
                return;
            disposed = true;
            shell.dispose();
            tabs.forEach((tab) => tab.dispose());
            tooltip.dispose();
            grid.dispose();
        },
    };
}
