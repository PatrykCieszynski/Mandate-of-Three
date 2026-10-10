import { errorMessage } from '../../protocol.js';
import { ownedItemPayload, itemGridPreview, itemWindowControls, } from '../../game-ui/items/item-drag-policy.js';
import { STORAGE_COLUMNS, STORAGE_ROWS, STORAGE_PAGES, STORAGE_PAGE_CELLS, ITEM_SLOT_SIZE, } from './storage-model.js';
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
        onCancel: () => {
            tooltip.hide();
            options.drag?.cancel();
        },
        canDrag: () => !options.drag?.active,
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
    capacity.textContent = `${STORAGE_PAGE_CELLS} slots per page · ${STORAGE_PAGES} pages`;
    const status = document.createElement('p');
    status.className = 'storage-status';
    status.setAttribute('role', 'status');
    status.hidden = true;
    shell.contentRoot.append(nav, viewport, capacity, status);
    const grid = UiItemGrid(gridRoot, { slotSize: () => ITEM_SLOT_SIZE });
    const tooltip = ItemTooltip(root, { geometry: () => options.manager });
    let state = {
        columns: STORAGE_COLUMNS,
        rows: STORAGE_ROWS,
        pages: STORAGE_PAGES,
        items: [],
    };
    const bindings = itemWindowControls(options.drag, root);
    const sourceBindings = [];
    let pending = false;
    let page = 0, disposed = false;
    const tabs = ['I', 'II'].map((label, index) => {
        const tab = UiTab({
            label,
            onSelect: () => {
                if (!options.drag?.latched)
                    options.drag?.cancel();
                options.drag?.refreshPreview();
                page = index;
                render();
            },
        });
        nav.append(tab.element);
        return tab;
    });
    function render() {
        sourceBindings.forEach((binding) => binding.dispose());
        sourceBindings.length = 0;
        tooltip.hide();
        grid.render({
            columns: state.columns,
            rows: state.rows,
            items: state.items.filter((item) => item.page === page),
        }, (item) => {
            const node = UiItemSlot({
                item,
                slotSize: ITEM_SLOT_SIZE,
                resolveItemIcon: options.resolveItemIcon,
            });
            if (options.drag)
                sourceBindings.push(options.drag.registerSource({
                    element: node,
                    payload: (event) => {
                        if (pending)
                            return null;
                        shell.handle.activate();
                        tooltip.hide();
                        if (event.ctrlKey) {
                            void withdrawToInventory(item);
                            return null;
                        }
                        return ownedItemPayload('storage', item, ITEM_SLOT_SIZE, options.resolveItemIcon);
                    },
                }));
            return node;
        });
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
        if (item && !shell.drag && !options.drag?.active)
            tooltip.show(event, item);
        else
            tooltip.hide();
    });
    shell.listen(gridRoot, 'pointerleave', () => tooltip.hide());
    shell.listen(gridRoot, 'pointerdown', (event) => {
        const item = itemFor(event);
        if (item)
            options.onItemAction?.(event, item);
    });
    async function submit(from, to, item, position) {
        if (pending || disposed || !options.transfer)
            return;
        pending = true;
        setStatus('Transferring…');
        try {
            const result = await options.transfer({
                id: item.id,
                revision: item.revision,
                from,
                to,
                x: position?.x ?? 0,
                y: position?.y ?? 0,
                page: position?.page ?? 0,
                quick: !position,
            });
            if (!disposed)
                setStatus(result.ok ? '' : `Transfer rejected: ${result.error ?? 'request'}`);
        }
        catch (error) {
            if (!disposed)
                setStatus(`Transfer failed: ${errorMessage(error)}`);
        }
        finally {
            pending = false;
        }
    }
    function receiveFromInventory(item, position) {
        return submit('inventory', 'storage', item, position);
    }
    function withdrawToInventory(item, position) {
        return submit('storage', 'inventory', item, position);
    }
    function setStatus(message) {
        status.textContent = message;
        status.hidden = message.length === 0;
        shell.refresh();
    }
    if (options.drag) {
        bindings.push(options.drag.registerControl(nav, 'preserve'));
        bindings.push(options.drag.registerTarget({
            element: gridRoot,
            preview: (payload, pointer) => {
                const preview = itemGridPreview(gridRoot, state, page, ITEM_SLOT_SIZE, payload, pointer);
                const valid = preview.valid &&
                    !pending &&
                    !!options.transfer &&
                    preview.data?.subject.container !== 'equipment';
                if (!valid)
                    preview.visual?.element.classList.add('invalid');
                return { ...preview, valid };
            },
            drop: async (_payload, preview) => {
                if (!preview.data)
                    return;
                const { subject, position } = preview.data;
                if (subject.container === 'inventory')
                    await receiveFromInventory(subject.item, position);
                else if (subject.container === 'storage')
                    await submit('storage', 'storage', subject.item, position);
            },
        }));
    }
    render();
    return {
        regions: [shell.panel],
        refresh: () => shell.refresh(),
        activate: () => shell.handle.activate(),
        setStatus,
        receiveFromInventory,
        tryQuickDeposit(item) {
            if (root.hidden || pending || disposed || !options.transfer)
                return null;
            return receiveFromInventory(item);
        },
        withdrawToInventory,
        setState(snapshot) {
            options.drag?.cancel();
            state = structuredClone(snapshot);
            render();
        },
        dispose() {
            if (disposed)
                return;
            disposed = true;
            sourceBindings.forEach((binding) => binding.dispose());
            bindings.forEach((binding) => binding.dispose());
            shell.dispose();
            tabs.forEach((tab) => tab.dispose());
            tooltip.dispose();
            grid.dispose();
        },
    };
}
