@tool
## DefTable 表格网格容器(变高行 + 行虚拟化)。
## 行高由外部(View)按单元格文本预计算后传入, 本容器只负责摆位与滚动定位,
## 保证滚动范围(row_offsets)精确且不随可见行变化抖动。
class_name DefTableGrid
extends Container

## 每列宽度
var column_widths: Array[float] = []
## 总行数
var total_rows: int = 0
## 每行高度(View 预计算)
var row_heights: Array[float] = []
## 每行起始 Y 偏移(累加行高, 供滚动定位)
var row_offsets: Array[float] = []
## 每列起始 X 偏移(累加列宽)
var column_offsets: Array[float] = []

## 列偏移: cell_pos.x 是全局列索引, 本网格从第几列开始渲染(冻结网格=0, 滚动网格=1)
var column_offset: int = 0

var _cached_minimum_size := Vector2.ZERO


func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		sort_children()


func _get_minimum_size() -> Vector2:
	return _cached_minimum_size


## 设置列宽与总行数。row_heights 需由 set_row_heights 提供。
func configure(widths: Array[float], rows_total: int) -> void:
	column_widths = widths.duplicate()
	total_rows = rows_total
	_recompute_offsets()
	queue_sort()


## 传入预计算的行高, 刷新偏移与滚动范围。
func set_row_heights(heights: Array[float]) -> void:
	row_heights = heights.duplicate()
	_recompute_offsets()
	queue_sort()


func _recompute_offsets() -> void:
	column_offsets.clear()
	var cx := 0.0
	for w in column_widths:
		column_offsets.append(cx)
		cx += w
	column_offsets.append(cx)

	row_offsets.clear()
	var cy := 0.0
	for h in row_heights:
		row_offsets.append(cy)
		cy += h
	row_offsets.append(cy)


## 行 y 坐标 -> 行索引 (变高行二分查找)
func row_index_at(y: float) -> int:
	if row_offsets.size() == 0 or y < 0.0:
		return 0
	var lo := 0
	var hi := row_offsets.size() - 2
	if hi < 0:
		return 0
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if row_offsets[mid] <= y:
			lo = mid
		else:
			hi = mid - 1
	return lo


## 由 Container 在布局时调用, 将子节点按行主序摆放(使用预计算行高)。
func sort_children() -> void:
	var ncols := column_widths.size()
	if ncols == 0:
		_cached_minimum_size = Vector2(0.0, 0.0)
		return

	var min_row_h := 24.0
	for child in get_children():
		if not (child is Control):
			continue
		var c := child as Control
		var meta := c.get_meta(&"cell_pos", Vector2i(-1, -1)) as Vector2i
		# cell_pos.x 是全局列索引, 布局时用网格内列索引(减去 column_offset)
		var gi := meta.x - column_offset
		if meta.y < 0 or meta.y >= total_rows or gi < 0 or gi >= ncols:
			continue
		var h := row_heights[meta.y] if meta.y < row_heights.size() else min_row_h
		if h < min_row_h:
			h = min_row_h
		fit_child_in_rect(c, Rect2(
			Vector2(column_offsets[gi], row_offsets[meta.y] if meta.y < row_offsets.size() else 0.0),
			Vector2(column_widths[gi], h)))

	var total_w := 0.0
	for w in column_widths:
		total_w += w
	var total_h := 0.0
	for h in row_heights:
		total_h += h
	_cached_minimum_size = Vector2(total_w, total_h)