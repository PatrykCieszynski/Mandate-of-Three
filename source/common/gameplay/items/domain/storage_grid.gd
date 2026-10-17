extends RefCounted
## Shared footprint geometry; no persistence, presentation or authority.
const COLUMNS: int = 15
const ROWS: int = 9
const PAGES: int = 2
const PAGE_CELLS: int = COLUMNS * ROWS
const CAPACITY: int = PAGE_CELLS * PAGES

static func cells(position: int, height: int) -> Array[int]:
	var result: Array[int] = []
	if position < 0 or position >= CAPACITY or height < 1 or height > 3 or (position % PAGE_CELLS) / COLUMNS + height > ROWS: return result
	for offset: int in height: result.append(position + offset * COLUMNS)
	return result
