import type { ShopOfferPresentation } from './shop-model.js';
// Presentation only: server order and item footprints determine a compact catalog.
// Offer positions never enter buy commands or imply ownership/capacity.
export function shopOfferLayout(offers: readonly ShopOfferPresentation[]) {
  const columns = 5,
    occupied = new Set<number>();
  let rows = 9;
  const items = offers.map((offer) => {
    let cell = 0;
    while (
      Array.from({ length: offer.height }, (_, dy) => cell + dy * columns).some(
        (index) => occupied.has(index),
      )
    )
      cell++;
    const x = cell % columns,
      y = Math.floor(cell / columns);
    for (let dy = 0; dy < offer.height; dy++) occupied.add(cell + dy * columns);
    rows = Math.max(rows, y + offer.height);
    return { ...offer, x, y };
  });
  return { columns, rows, items };
}
