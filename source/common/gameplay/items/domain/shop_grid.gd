extends RefCounted
## Seller grid geometry, shared without depending on a SQL implementation.
const COLUMNS: int = 5
const ROWS: int = 8
const CAPACITY: int = COLUMNS * ROWS

static func cells(position: int, height: int) -> Array[int]:
	var result: Array[int]=[]
	if position<0 or height<1 or height>3 or position+COLUMNS*(height-1)>=CAPACITY: return result
	for row: int in height: result.append(position+COLUMNS*row)
	return result
