@tool
class_name TownPlazaStep extends TownStepDef
## 广场 + 中心设施

@export_range(0, 12, 1) var radius := 4
@export var feature := "水井"


func apply(ctx: TownGenContext) -> void:
	var layout := ctx.layout
	var r := radius
	var sum := Vector2.ZERO
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if dx * dx + dy * dy > r * r: continue
			var x := ctx.site.x + dx
			var y := ctx.site.y + dy
			if layout.roads_grid.in_bounds(x, y) and layout.roads_grid.get_cell(x, y, 0) == 0:
				layout.plaza_cells.append(y * layout.roads_grid.width + x)
				sum += Vector2(x, y)
	if not layout.plaza_cells.is_empty():
		var centroid := sum / float(layout.plaza_cells.size())
		var best: int = layout.plaza_cells[0]; var bd := INF
		for idx in layout.plaza_cells:
			var dd := Vector2(int(idx) % layout.roads_grid.width, int(idx) / layout.roads_grid.width).distance_squared_to(centroid)
			if dd < bd: bd = dd; best = int(idx)
		layout.plaza_center = Vector2i(int(best) % layout.roads_grid.width, int(best) / layout.roads_grid.width)
		layout.plaza_item = feature
