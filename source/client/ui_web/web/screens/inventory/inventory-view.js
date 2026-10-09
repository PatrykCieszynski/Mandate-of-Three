import { ownedItemPayload, itemGridPreview, itemWindowControls, } from '../../game-ui/items/item-drag-policy.js';
import { element as findElement } from '../../core/dom.js';
import { errorMessage } from '../../protocol.js';
import { UiTab } from '../../core/primitives/ui-tab.js';
import { UiItemGrid } from '../../game-ui/items/ui-item-grid.js';
import { UiItemSlot } from '../../game-ui/items/ui-item-slot.js';
import { ItemTooltip } from '../../game-ui/items/item-tooltip.js';
import { UiCurrency } from '../../core/primitives/ui-currency.js';
import { UiWindow } from '../../core/window/ui-window.js';
import { firstFittingPlacement } from './placement.js';
export function mountInventory(root, { manager, drag, quickDeposit, withdrawItem, receiveEquipped, resolveItemIcon = () => null, moveItem, activateItem, onClose = () => { }, onRegionsChanged = () => { }, }) {
    const shell = new UiWindow(root, {
        id: 'inventory',
        title: 'Inventory',
        className: 'window',
        manager,
        placement: {
            kind: 'viewport',
            anchor: 'top-right',
            offset: { x: -16, y: 240 },
        },
        scrollBorder: 2,
        hideHorizontalOverflow: true,
        onClose,
        canDrag: () => !drag?.active,
        onCancel: () => cancelCarry(),
        onRegionsChanged,
    });
    shell.contentRoot.innerHTML = `<nav class="inventory-tabs" aria-label="Inventory pages"></nav>
    <div class="inventory-grid"></div><footer class="wallet"></footer>
    <p class="inventory-status" role="status"></p>`;
    const panel = findElement(root, '.window', 'section'), grid = findElement(root, '.inventory-grid', 'div'), status = findElement(root, '.inventory-status', 'p');
    const tip = ItemTooltip(root, { geometry: () => manager }), tooltip = tip.element, currency = UiCurrency(findElement(root, '.wallet', 'footer'), {
        label: 'Yang',
        iconId: 'currencies.yang',
    });
    const tabs = ['I', 'II', 'III', 'IV'].map((label, index) => {
        const tab = UiTab({
            label,
            onSelect: () => {
                if (!drag?.latched)
                    cancelCarry();
                drag?.refreshPreview();
                page = index;
                render();
            },
        });
        findElement(root, '.inventory-tabs', 'nav').append(tab.element);
        return tab;
    });
    let inventory = {
        columns: 5,
        rows: 9,
        pages: 4,
        items: [],
    }, page = 0, pending = false, disposed = false;
    const sourceBindings = [];
    const bindings = itemWindowControls(drag, root);
    const cell = () => parseFloat(getComputedStyle(grid).getPropertyValue('--slot-size'));
    const positionWindow = () => shell.refresh();
    const gridView = UiItemGrid(grid, { slotSize: cell });
    function render() {
        for (const binding of sourceBindings)
            binding.dispose();
        sourceBindings.length = 0;
        gridView.render({
            columns: inventory.columns,
            rows: inventory.rows,
            items: inventory.items.filter((item) => item.page === page),
        }, (item) => {
            const node = UiItemSlot({ item, slotSize: cell(), resolveItemIcon });
            node.classList.add('inventory-item');
            if (drag)
                sourceBindings.push(drag.registerSource({
                    element: node,
                    payload: (event) => {
                        if (pending)
                            return null;
                        shell.handle.activate();
                        tip.hide();
                        if (event.ctrlKey && quickDeposit) {
                            void quickDeposit(item);
                            return null;
                        }
                        return ownedItemPayload('inventory', item, cell(), resolveItemIcon);
                    },
                }));
            node.addEventListener('pointerdown', (event) => {
                if (event.button === 2 && activateItem && !drag?.active && !pending) {
                    event.preventDefault();
                    activate(item);
                }
            });
            node.addEventListener('pointermove', (event) => {
                if (!drag?.active && !pending)
                    showTooltip(event, item);
            });
            node.addEventListener('pointerleave', () => (tooltip.hidden = true));
            return node;
        });
        tabs.forEach((tab, index) => tab.setSelected(index === page));
        positionWindow();
    }
    function showTooltip(event, item) {
        tip.show(event, item);
    }
    function cancelCarry() {
        drag?.cancel();
        tip.hide();
    }
    async function activate(item) {
        if (!activateItem)
            return;
        pending = true;
        tooltip.hidden = true;
        status.textContent = 'Activating…';
        try {
            const result = await activateItem({
                id: item.id,
                revision: item.revision,
            });
            if (!disposed)
                status.textContent = result.ok
                    ? ''
                    : `Activation rejected: ${result.error || 'request'}`;
        }
        catch (error) {
            if (!disposed)
                status.textContent = `Activation failed: ${errorMessage(error)}`;
        }
        finally {
            pending = false;
        }
    }
    async function move(item, preview) {
        if (pending)
            return;
        pending = true;
        status.textContent = 'Moving…';
        try {
            const result = await moveItem({
                id: item.id,
                revision: item.revision,
                x: preview.x,
                y: preview.y,
                page: preview.page,
            });
            if (!disposed)
                status.textContent = result.ok
                    ? ''
                    : `Move rejected: ${result.error || 'request'}`;
        }
        catch (error) {
            if (!disposed)
                status.textContent = `Move failed: ${errorMessage(error)}`;
        }
        finally {
            pending = false;
        }
    }
    if (drag) {
        bindings.push(drag.registerControl(findElement(root, '.inventory-tabs', 'nav'), 'preserve'));
        bindings.push(drag.registerTarget({
            element: grid,
            preview: (payload, pointer) => {
                const preview = itemGridPreview(grid, inventory, page, cell(), payload, pointer);
                if (pending || !preview.data) {
                    preview.visual?.element.classList.add('invalid');
                    return { ...preview, valid: false };
                }
                const subject = preview.data.subject;
                if (subject.container === 'equipment') {
                    // The existing unequip wire command receives automatically, with no coordinates.
                    const valid = !!receiveEquipped &&
                        firstFittingPlacement(inventory, subject.item) !== null;
                    const highlight = document.createElement('div');
                    highlight.className =
                        'item-drop-highlight' + (valid ? '' : ' invalid');
                    return {
                        ...preview,
                        valid,
                        visual: { element: highlight, parent: grid },
                    };
                }
                const valid = preview.valid &&
                    (subject.container === 'inventory' || !!withdrawItem);
                if (!valid)
                    preview.visual?.element.classList.add('invalid');
                return { ...preview, valid };
            },
            drop: async (_payload, preview) => {
                const data = preview.data;
                if (!data)
                    return;
                if (data.subject.container === 'inventory')
                    await move(data.subject.item, data.position);
                else if (data.subject.container === 'storage')
                    await receiveFromStorage(data.subject.item, data.position);
                else
                    await receiveEquipped?.(data.subject.item);
            },
        }));
    }
    // Supplied position is exact; absence requests authoritative first-fitting receipt.
    function receiveFromStorage(item, position) {
        return withdrawItem?.(item, position) ?? Promise.resolve();
    }
    function cancelOrClose() {
        if (drag?.active)
            cancelCarry();
        else
            onClose();
    }
    function keyDown(event) {
        if (root.hidden || event.repeat)
            return;
        if (event.key === 'Escape' || event.key.toLowerCase() === 'i') {
            event.preventDefault();
            if (event.key === 'Escape')
                cancelOrClose();
            else {
                cancelCarry();
                onClose();
            }
        }
    }
    shell.listen(document, 'keydown', keyDown);
    render();
    return {
        regions: [panel],
        cancelCarry,
        cancelOrClose,
        receiveFromStorage,
        setState(snapshot) {
            cancelCarry();
            inventory = structuredClone(snapshot.inventory);
            render();
        },
        setInfo(snapshot) {
            currency.setValue(snapshot.wallet?.balance);
        },
        refresh: () => shell.refresh(),
        activate: () => shell.handle.activate(),
        dispose() {
            if (disposed)
                return;
            disposed = true;
            sourceBindings.forEach((binding) => binding.dispose());
            bindings.forEach((binding) => binding.dispose());
            shell.dispose();
            tabs.forEach((tab) => tab.dispose());
            tip.dispose();
            currency.dispose();
            gridView.dispose();
        },
    };
}
