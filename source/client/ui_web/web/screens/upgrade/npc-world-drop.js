import { OwnedItemDragSubject } from '../../game-ui/items/item-drag-policy.js';
export function mountNpcWorldDrop(drag, drop, changed) {
    const root = document.createElement('div');
    root.className = 'npc-world-drop';
    root.dataset.carrying = 'false';
    document.body.prepend(root);
    const entries = new Map();
    let snapshot = { width: 0, height: 0, targets: [] };
    function layout() {
        // Services share the NPC hit surface, so overlapping rectangles cannot hide
        // the service whose recipe accepts the carried item. Preserve content order.
        const grouped = new Map();
        if (snapshot.width && snapshot.height)
            for (const target of snapshot.targets) {
                const targets = grouped.get(target.npcInstanceId) ?? [];
                targets.push(target);
                grouped.set(target.npcInstanceId, targets);
            }
        for (const [id, entry] of entries)
            if (!grouped.has(id)) {
                entry.binding.dispose();
                entry.node.remove();
                entries.delete(id);
            }
        for (const [id, targets] of grouped) {
            let entry = entries.get(id);
            const target = targets[0];
            const node = entry?.node ?? document.createElement('div');
            node.className = 'npc-world-drop-target';
            node.style.left = (target.x * window.innerWidth) / snapshot.width + 'px';
            node.style.top = (target.y * window.innerHeight) / snapshot.height + 'px';
            node.style.width = (target.w * window.innerWidth) / snapshot.width + 'px';
            node.style.height =
                (target.h * window.innerHeight) / snapshot.height + 'px';
            if (entry) {
                entry.targets = targets;
                continue;
            }
            root.append(node);
            const binding = drag.registerTarget({
                element: node,
                preview: (payload) => {
                    const subject = payload.subject instanceof OwnedItemDragSubject &&
                        payload.subject.container === 'inventory'
                        ? payload.subject
                        : null;
                    const matching = subject
                        ? entries
                            .get(id)
                            ?.targets.find((t) => subject.item.definition_id === t.itemDefinitionId &&
                            subject.item.upgrade_level === t.fromLevel)
                        : undefined;
                    node.dataset.valid = matching ? 'true' : 'false';
                    return {
                        valid: !!matching,
                        data: subject && matching ? { subject, target: matching } : null,
                    };
                },
                drop: async (_payload, preview) => {
                    if (preview.valid && preview.data) {
                        const { subject, target } = preview.data;
                        await drop(target.npcInstanceId, target.serviceId, {
                            id: subject.item.id,
                            revision: subject.item.revision,
                        });
                    }
                },
            });
            entries.set(id, { node, binding, targets });
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
            const next = String(active);
            if (root.dataset.carrying !== next)
                entries.forEach(({ node }) => delete node.dataset.valid);
            root.dataset.carrying = next;
        },
        dispose() {
            entries.forEach((entry) => entry.binding.dispose());
            entries.clear();
            root.remove();
        },
    };
}
