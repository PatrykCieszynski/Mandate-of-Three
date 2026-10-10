// Catalog pages are presentation only; buy commands still use opaque offer IDs.
export function shopOfferLayout(offers) {
    const columns = 5, rows = 9;
    const pages = [[]];
    let occupied = new Set();
    function findCell(height) {
        for (let y = 0; y + height <= rows; y++)
            for (let x = 0; x < columns; x++) {
                const cell = y * columns + x;
                if (Array.from({ length: height }, (_, dy) => cell + dy * columns).every((index) => !occupied.has(index)))
                    return cell;
            }
        return -1;
    }
    for (const offer of offers) {
        let cell = findCell(offer.height);
        if (cell < 0) {
            pages.push([]);
            occupied = new Set();
            cell = 0;
        }
        const x = cell % columns, y = Math.floor(cell / columns);
        for (let dy = 0; dy < offer.height; dy++)
            occupied.add(cell + dy * columns);
        pages[pages.length - 1].push({ ...offer, x, y });
    }
    return { columns, rows, pages };
}
