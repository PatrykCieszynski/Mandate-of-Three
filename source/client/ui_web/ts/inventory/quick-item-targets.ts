import type { ItemPresentation } from '../game-ui/item-types.js';

// Open order, independent of focus: clicking Inventory must not replace the destination.
export class QuickItemTargets {
  private open: Target[] = [];
  constructor(private readonly targets: Target[]) {}
  sync() {
    const visible = this.targets.filter((target) => !target.root.hidden);
    this.open = this.open.filter((target) => visible.includes(target));
    for (const target of visible)
      if (!this.open.includes(target)) this.open.push(target);
  }
  receive(item: ItemPresentation): Promise<void> | null {
    this.sync();
    const target = this.open.at(-1);
    if (!target) return null;
    // A busy/rejecting destination never redirects the item to an older window.
    return Promise.resolve(target.receive(item)).then(
      () => {},
      () => {},
    );
  }
}
interface Target {
  root: Pick<HTMLElement, 'hidden'>;
  receive: (item: ItemPresentation) => Promise<unknown> | null;
}
