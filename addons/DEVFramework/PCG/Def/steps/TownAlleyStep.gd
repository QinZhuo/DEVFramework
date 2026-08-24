@tool
class_name TownAlleyStep extends TownStepDef
## 巷道细分 — 递归空间细分刻巷道


func apply(ctx: TownGenContext) -> void:
	var def: TownDef = ctx.def
	var roads := ctx.layout.roads_grid
	var hm := ctx.heightmap
	var rng := ctx.next_rng()
	var bounds := Rect2i(); var first := true
	for y in roads.height:
		for x in roads.width:
			if roads.get_cell(x, y, 0) != 0:
				if first: bounds = Rect2i(x, y, 1, 1); first = false
				else: bounds = bounds.expand(Vector2i(x, y))
	if first: return
	var root := bounds.grow(2).intersection(Rect2i(0, 0, roads.width, roads.height))
	var stack: Array[Rect2i] = [root]
	var guard := 0
	while not stack.is_empty() and guard < 512:
		guard += 1
		var r: Rect2i = stack.pop_back()
		if r.size.x * r.size.y <= def.lot_max_area * 3: continue
		var vertical := r.size.x >= r.size.y
		var cut_pos := -1
		if vertical:
			cut_pos = clampi(r.position.x + int(r.size.x * rng.randf_range(0.35, 0.65)), r.position.x + 2, r.end.x - 3)
			for yy in range(r.position.y, r.end.y):
				if roads.get_cell(cut_pos, yy, 0) == 0:
					roads.set_cell(cut_pos, yy, def.road_alley_value)
		else:
			cut_pos = clampi(r.position.y + int(r.size.y * rng.randf_range(0.35, 0.65)), r.position.y + 2, r.end.y - 3)
			for xx in range(r.position.x, r.end.x):
				if roads.get_cell(xx, cut_pos, 0) == 0:
					roads.set_cell(xx, cut_pos, def.road_alley_value)
