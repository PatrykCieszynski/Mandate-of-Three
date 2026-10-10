import { OwnedItemDragSubject } from '../../game-ui/items/item-drag-policy.js';
export function mountNpcWorldDrop(drag, drop, changed) {
    const root = document.createElement('div');
    root.className = 'npc-world-drop';
    root.dataset.carrying = 'false';
    document.body.prepend(root);
    const entries = new Map();
    let snapshot = { width: 0, height: 0, targets: [] };
    function layout() {
        const ids = new Set(snapshot.width && snapshot.height
            ? snapshot.targets.map((t) => t.id)
            : []);
        for (const [id, entry] of entries)
            if (!ids.has(id)) {
                entry.binding.dispose();
                entry.node.remove();
                entries.delete(id);
            }
        if (!snapshot.width || !snapshot.height)
            return;
        for (const target of snapshot.targets) {
            let entry = entries.get(target.id);
            const node = entry?.node ?? document.createElement('div');
            node.className = 'npc-world-drop-target';
            node.style.left = (target.x * window.innerWidth) / snapshot.width + 'px';
            node.style.top = (target.y * window.innerHeight) / snapshot.height + 'px';
            node.style.width = (target.w * window.innerWidth) / snapshot.width + 'px';
            node.style.height =
                (target.h * window.innerHeight) / snapshot.height + 'px';
            if (entry)
                continue;
            root.append(node);
            const binding = drag.registerTarget({
                element: node,
                preview: (payload) => {
                    const subject = payload.subject instanceof OwnedItemDragSubject &&
                        payload.subject.container === 'inventory' &&
                        payload.subject.item.definition_id === 'iron_sword' &&
                        payload.subject.item.upgrade_level === 0
                        ? payload.subject
                        : null;
                    node.dataset.valid = subject ? 'true' : 'false';
                    return { valid: !!subject, data: subject };
                },
                drop: async (_payload, preview) => {
                    if (preview.valid && preview.data)
                        await drop(target.id, {
                            id: preview.data.item.id,
                            revision: preview.data.item.revision,
                        });
                },
            });
            entries.set(target.id, { node, binding });
        }
    }
    return {
        regions: [],
        setState(value) {
            snapshot = value;
            layout();
            changed();
        },
        setCarrying(active) {
            root.dataset.carrying = String(active);
        },
        dispose() {
            entries.forEach((entry) => entry.binding.dispose());
            entries.clear();
            root.remove();
        },
    };
}
