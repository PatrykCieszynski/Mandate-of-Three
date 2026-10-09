class_name InventoryGrid
extends RefCounted
const COLUMNS: int = 5
const ROWS: int = 9
const PAGES: int = 4
const PAGE_CELLS: int = COLUMNS * ROWS
const CAPACITY: int = PAGE_CELLS * PAGES

static func cells(position: int, height: int) -> Array[int]:
	var result: Array[int] = []
	if position < 0 or position >= CAPACITY or height < 1 or height > 3:
		return result
	var row: int = (position % PAGE_CELLS) / COLUMNS
	if row + height > ROWS: return result
	for offset: int in height: result.append(position + offset * COLUMNS)
	return result

static func fits(position: int, height: int, occupied: Dictionary) -> bool:
	var footprint: Array[int] = cells(position, height)
	return not footprint.is_empty() and not footprint.any(func(cell: int) -> bool: return occupied.has(cell))
