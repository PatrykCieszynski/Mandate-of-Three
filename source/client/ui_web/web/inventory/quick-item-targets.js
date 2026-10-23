// Open order, independent of focus: clicking Inventory must not replace the destination.
export class QuickItemTargets {
    targets;
    open = [];
    constructor(targets) {
        this.targets = targets;
    }
    sync() {
        const visible = this.targets.filter((target) => !target.root.hidden);
        this.open = this.open.filter((target) => visible.includes(target));
        for (const target of visible)
            if (!this.open.includes(target))
                this.open.push(target);
    }
    receive(item) {
        this.sync();
        const target = this.open.at(-1);
        if (!target)
            return null;
        // A busy/rejecting destination never redirects the item to an older window.
        return Promise.resolve(target.receive(item)).then(() => { }, () => { });
    }
}
