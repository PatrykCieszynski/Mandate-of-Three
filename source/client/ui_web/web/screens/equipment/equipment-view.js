import { element as findElement } from '../../core/dom.js';
import { errorMessage } from '../../protocol.js';
import { UiEquipmentSlot } from '../../game-ui/equipment/ui-equipment-slot.js';
import { ItemTooltip } from '../../game-ui/items/item-tooltip.js';
import { UiWindow } from '../../core/window/ui-window.js';
// Layout of the 156×188 reference equipment panel. Coordinates include the
// original slot container's (3,3) inset; these are screen geometry, not skin data.
const slots = [
    ['weapon', 'Weapon', 6, 6, 96],
    ['head', 'Helmet', 42, 5, 32],
    ['neck', 'Necklace', 117, 87, 32],
    ['armor', 'Armor', 42, 40, 64],
    ['earrings', 'Earrings', 117, 55, 32],
    ['bracelet', 'Bracelet', 78, 70, 32],
    ['shield', 'Shield', 78, 38, 32],
    ['feet', 'Shoes', 42, 148, 32],
    ['arrows', 'Arrows', 117, 4, 32],
    ['special1', 'Special slot I', 5, 116, 32],
    ['special2', 'Special slot II', 78, 116, 32],
];
export function mountEquipment(root, { manager, resolveItemIcon = () => null, unequipItem, onClose = () => { }, onRegionsChanged = () => { }, }) {
    const shell = new UiWindow(root, {
        id: 'equipment',
        title: 'Equipment',
        className: 'equipment-window',
        manager,
        placement: {
            kind: 'relative',
            target: 'inventory',
            side: 'left',
            align: 'start',
            gap: 12,
            fallback: {
                kind: 'viewport',
                anchor: 'top-right',
                offset: { x: -16, y: 240 },
            },
        },
        onClose,
        onRegionsChanged,
        onCancel: () => {
            tooltip.hidden = true;
        },
    });
    shell.contentRoot.innerHTML = `<div class="equipment-body"><div class="equipment-silhouette" aria-hidden="true">♟</div></div>
    <p class="equipment-stats"></p><p class="equipment-hint">Right-click bag items to equip.<br>Click weapon to unequip.</p>
    <p class="inventory-status" role="status"></p>`;
    const panel = findElement(root, '.equipment-window', 'section'), body = findElement(root, '.equipment-body', 'div'), status = findElement(root, '[role=status]', 'p');
    const tip = ItemTooltip(root, { geometry: () => manager }), tooltip = tip.element;
    let pending = false, disposed = false;
    let items = [];
    const buttons = new Map();
    for (const [slot, label, x, y, height] of slots) {
        const tile = UiEquipmentSlot({
            slot,
            label,
            x,
            y,
            height,
            resolveItemIcon,
            title: slot === 'weapon' ? label : label + ' · not available yet',
        }), button = tile.element;
        shell.listen(button, 'pointermove', (event) => showTooltip(event, slot));
        shell.listen(button, 'pointerleave', () => (tooltip.hidden = true));
        shell.listen(button, 'click', async () => {
            const item = items.find((item) => item.slot === slot);
            if (!item || pending)
                return;
            pending = true;
            tooltip.hidden = true;
            render();
            status.textContent = 'Unequipping…';
            try {
                const result = await unequipItem({
                    id: item.id,
                    revision: item.revision,
                });
                if (!disposed)
                    status.textContent = result.ok
                        ? ''
                        : `Unequip rejected: ${result.error || 'request'}`;
            }
            catch (error) {
                if (!disposed)
                    status.textContent = `Unequip failed: ${errorMessage(error)}`;
            }
            finally {
                pending = false;
                if (!disposed)
                    render();
            }
        });
        buttons.set(slot, tile);
        body.append(button);
    }
    function showTooltip(event, slot) {
        const item = items.find((item) => item.slot === slot);
        if (!item || pending || shell.drag)
            return;
        tip.show(event, item);
    }
    function render() {
        for (const [slot, tile] of buttons) {
            const item = items.find((item) => item.slot === slot);
            tile.setItem(item, { enabled: slot === 'weapon' && !!item && !pending });
        }
    }
    return {
        regions: [panel],
        close: onClose,
        refresh: () => shell.refresh(),
        activate: () => shell.handle.activate(),
        setState(state) {
            tooltip.hidden = true;
            items = state.equipment?.items || [];
            render();
            findElement(root, '.equipment-stats', 'p').textContent =
                'Attack ' + Number(state.equipment?.stats?.attack || 0);
            shell.refresh();
        },
        dispose() {
            disposed = true;
            shell.dispose();
            tip.dispose();
        },
    };
}
