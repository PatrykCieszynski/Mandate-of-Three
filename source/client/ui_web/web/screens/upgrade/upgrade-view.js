import { UiWindow } from '../../core/window/ui-window.js';
import { UiButton } from '../../core/primitives/ui-button.js';
import { UiSlot } from '../../core/primitives/ui-slot.js';
import { paintItemIcon } from '../../game-ui/items/item-icon.js';
import { ItemTooltip } from '../../game-ui/items/item-tooltip.js';
import { itemRarity } from '../../game-ui/items/item-tooltip-model.js';
import { OwnedItemDragSubject, itemWindowControls, } from '../../game-ui/items/item-drag-policy.js';
import { npcOpening, NpcServiceKind } from '../npc/npc-model.js';
import { MAX_UPGRADE_LEVEL, previewItemLevel, upgradeExample, upgradePreview, } from './upgrade-preview.js';
export function mountUpgrade(root, options) {
    let item = null, level = 0, confirmed = false, key = '', disposed = false;
    const shell = new UiWindow(root, {
        id: 'upgrade',
        title: 'Upgrade',
        className: 'upgrade-window',
        manager: options.manager,
        placement: {
            kind: 'relative',
            target: 'inventory',
            side: 'left',
            align: 'start',
            gap: 12,
            fallback: {
                kind: 'viewport',
                anchor: 'top-left',
                offset: { x: 16, y: 180 },
            },
        },
        scrollBorder: 2,
        hideHorizontalOverflow: true,
        canDrag: () => !options.drag.active,
        onCancel: () => options.drag.cancel(),
        onClose: () => closeIfActive(),
        ...(options.onRegionsChanged
            ? { onRegionsChanged: options.onRegionsChanged }
            : {}),
    });
    shell.contentRoot.innerHTML = `<div class="upgrade-body"><div class="upgrade-item-summary"><div class="upgrade-item-target" aria-label="Item to upgrade"></div>
    <div class="upgrade-item-details"><h2 class="upgrade-name"></h2><p class="upgrade-category"></p>
    <p class="upgrade-prompt">Drag an Iron Sword from Inventory into the slot.</p></div></div>
    <div class="upgrade-comparison"><p class="upgrade-transition"></p><div class="upgrade-properties"></div>
    <div class="upgrade-affixes"></div><div class="upgrade-requirements"></div></div>
    <div class="upgrade-recipe"><div class="upgrade-material"><span class="upgrade-material-symbol" aria-hidden="true">◆</span><span class="upgrade-material-name"></span></div>
    <p class="upgrade-cost"></p><p class="upgrade-chance">Success: 100%</p></div>
    <p class="upgrade-max">Maximum upgrade level reached.</p></div>
    <p class="upgrade-notice">Preview only. Items and Yang are unchanged.</p>
    <div class="upgrade-confirmation" role="group" aria-label="Confirm upgrade" hidden><p class="upgrade-confirm-text"></p></div>
    <div class="upgrade-primary-actions upgrade-actions"></div>`;
    const find = (selector) => root.querySelector(selector);
    const target = find('.upgrade-item-target'), name = find('.upgrade-name'), confirmation = find('.upgrade-confirmation');
    const tip = ItemTooltip(root, { geometry: () => options.manager });
    const slot = UiSlot({
        className: 'ui-item-slot upgrade-slot',
        label: 'Item to upgrade',
    });
    target.append(slot);
    // Explicit opt-in on the separate dev page; never mount tooling in the game.
    const devControls = options.devPreview ? createDevControls() : undefined;
    function createDevControls() {
        const controls = document.createElement('div');
        controls.className = 'upgrade-preview-controls';
        controls.innerHTML =
            '<div class="upgrade-level-controls"><span>Preview level</span><output class="upgrade-level" aria-label="Preview level">+0</output></div>';
        const output = controls.querySelector('output');
        const example = UiButton({
            label: 'Preview Iron Sword',
            className: 'upgrade-example',
            onClick: () => choose(upgradeExample),
        });
        const previous = UiButton({ label: '−', onClick: () => changeLevel(-1) });
        const next = UiButton({ label: '+', onClick: () => changeLevel(1) });
        previous.element.setAttribute('aria-label', 'Previous preview level');
        next.element.setAttribute('aria-label', 'Next preview level');
        output.before(previous.element);
        output.after(next.element);
        controls.append(example.element);
        find('.upgrade-notice').before(controls);
        return { element: controls, output, example, previous, next };
    }
    function changeLevel(delta) {
        if (!options.devPreview || !item || confirmed)
            return;
        level = Math.max(0, Math.min(MAX_UPGRADE_LEVEL, level + delta));
        tip.hide();
        render();
    }
    const upgrade = UiButton({
        label: 'Upgrade',
        className: 'upgrade-cta',
        onClick: () => {
            if (!item || level === MAX_UPGRADE_LEVEL)
                return;
            confirmed = true;
            tip.hide();
            render();
            yes.element.focus({ preventScroll: true });
        },
    });
    const cancel = UiButton({
        label: 'Cancel',
        className: 'upgrade-cancel',
        onClick: () => closeIfActive(),
    });
    const yes = UiButton({
        label: 'Confirm',
        className: 'upgrade-cta',
        onClick: () => {
            if (!confirmed || !item || level >= MAX_UPGRADE_LEVEL)
                return;
            confirmed = false;
            level++;
            render();
            (level === MAX_UPGRADE_LEVEL ? cancel : upgrade).element.focus({
                preventScroll: true,
            });
        },
    });
    const no = UiButton({
        label: 'Back',
        onClick: () => {
            confirmed = false;
            render();
            upgrade.element.focus({ preventScroll: true });
        },
    });
    const confirmActions = document.createElement('div');
    confirmActions.className = 'upgrade-actions';
    confirmActions.append(yes.element, no.element);
    confirmation.append(confirmActions);
    find('.upgrade-primary-actions').append(upgrade.element, cancel.element);
    shell.listen(slot, 'pointermove', (event) => {
        if (item && !options.drag.active && !confirmed)
            tip.show(event, upgradePreview(item, level).current);
    });
    shell.listen(slot, 'pointerleave', () => tip.hide());
    const bindings = itemWindowControls(options.drag, root);
    bindings.push(options.drag.registerControl(confirmation, 'cancel'), options.drag.registerControl(find('.upgrade-primary-actions'), 'cancel'), options.drag.registerTarget({
        element: target,
        preview: (payload) => {
            const subject = payload.subject instanceof OwnedItemDragSubject &&
                payload.subject.container === 'inventory'
                ? payload.subject
                : null;
            const valid = !confirmed && !!subject && previewItemLevel(subject.item) !== null;
            const marker = document.createElement('div');
            marker.className = 'upgrade-drop-preview' + (valid ? '' : ' invalid');
            marker.textContent = valid ? 'Select item' : 'Iron Sword required';
            return {
                valid,
                data: subject,
                visual: { element: marker, parent: target },
            };
        },
        drop: (_payload, preview) => {
            if (preview.valid && preview.data)
                choose(preview.data.item);
        },
    }));
    if (devControls)
        bindings.push(options.drag.registerControl(devControls.element, 'cancel'));
    function choose(value) {
        const initial = previewItemLevel(value);
        if (initial === null || root.hidden || disposed)
            return;
        options.drag.cancel();
        item = structuredClone(value);
        level = initial;
        confirmed = false;
        tip.hide();
        render();
    }
    function lines(selector, values) {
        const node = find(selector);
        node.replaceChildren(...values.map((text) => {
            const p = document.createElement('p');
            p.textContent = text;
            return p;
        }));
        node.hidden = !values.length;
    }
    function render() {
        if (disposed)
            return;
        const preview = item ? upgradePreview(item, level) : null;
        slot.style.height = `${(item?.height ?? 2) * 40 - 2}px`;
        if (preview)
            paintItemIcon(slot, preview.current, {
                resolveItemIcon: options.resolveItemIcon,
                quantity: false,
            });
        else {
            slot.replaceChildren();
            const empty = document.createElement('span');
            empty.className = 'upgrade-empty-slot';
            empty.textContent = '+';
            slot.append(empty);
        }
        name.textContent = preview?.current.name ?? 'Select an item';
        name.dataset.rarity = itemRarity(item?.tooltip?.affixes?.length ?? 0);
        find('.upgrade-category').textContent = item?.tooltip?.category ?? '';
        find('.upgrade-category').hidden = !item?.tooltip?.category;
        find('.upgrade-prompt').hidden = !!item;
        find('.upgrade-comparison').hidden = !item;
        find('.upgrade-transition').textContent = preview?.next
            ? `+${level} → +${level + 1}`
            : `+${MAX_UPGRADE_LEVEL}`;
        lines('.upgrade-properties', (preview?.current.tooltip.properties ?? []).map((line, index) => {
            const nextLine = preview?.next?.tooltip.properties[index];
            const currentLine = line.replace(/^Attack: /, 'Attack ');
            return nextLine && nextLine !== line
                ? `${currentLine} → ${nextLine.replace(/^Attack: /, '')}`
                : currentLine;
        }));
        lines('.upgrade-affixes', item?.tooltip?.affixes?.flatMap((affix) => [...affix.lines]) ?? []);
        lines('.upgrade-requirements', item?.tooltip?.requirements ?? []);
        find('.upgrade-recipe').hidden = !preview?.next;
        find('.upgrade-material-name').textContent =
            `Upgrade material × ${preview?.materialCount ?? 0}`;
        find('.upgrade-cost').textContent =
            `${(preview?.cost ?? 0).toLocaleString('en-US')} Yang`;
        find('.upgrade-max').hidden = !item || level !== MAX_UPGRADE_LEVEL;
        if (devControls) {
            devControls.previous.setDisabled(!item || confirmed || level === 0);
            devControls.next.setDisabled(!item || confirmed || level === MAX_UPGRADE_LEVEL);
            devControls.output.value = `+${level}`;
            devControls.example.setDisabled(confirmed);
        }
        confirmation.hidden = !confirmed;
        find('.upgrade-confirm-text').textContent =
            `Upgrade to ${preview?.next?.name ?? ''} for ${(preview?.cost ?? 0).toLocaleString('en-US')} Yang?`;
        upgrade.element.hidden = confirmed;
        cancel.element.hidden = confirmed;
        upgrade.setDisabled(!item || level === MAX_UPGRADE_LEVEL);
        shell.refresh();
        options.onRegionsChanged?.();
    }
    function closeIfActive() {
        if (root.hidden)
            return false;
        options.drag.cancel();
        tip.hide();
        if (confirmed) {
            confirmed = false;
            render();
            upgrade.element.focus({ preventScroll: true });
        }
        else
            options.onClose();
        return true;
    }
    return {
        regions: [shell.panel],
        closeIfActive,
        setNpcState(snapshot) {
            const opening = npcOpening(snapshot);
            const nextKey = snapshot.active &&
                opening.mode === 'service' &&
                opening.service.kind === NpcServiceKind.UPGRADE
                ? `${snapshot.npcInstanceId}:${opening.service.id}`
                : '';
            if (key !== nextKey) {
                item = null;
                level = 0;
                confirmed = false;
                tip.hide();
            }
            const wasHidden = root.hidden;
            key = nextKey;
            root.hidden = !key;
            render();
            if (key && wasHidden)
                shell.handle.activate();
        },
        setInventory(snapshot) {
            if (!item || (options.devPreview && item.id === upgradeExample.id))
                return;
            const current = snapshot.items.find((entry) => entry.id === item.id);
            if (!current || previewItemLevel(current) === null) {
                item = null;
                confirmed = false;
                tip.hide();
                render();
            }
            else if (current.revision !== item.revision)
                choose(current);
        },
        dispose() {
            if (disposed)
                return;
            disposed = true;
            bindings.forEach((binding) => binding.dispose());
            [upgrade, cancel, yes, no].forEach((button) => button.dispose());
            if (devControls)
                [devControls.example, devControls.previous, devControls.next].forEach((button) => button.dispose());
            tip.dispose();
            shell.dispose();
        },
    };
}
