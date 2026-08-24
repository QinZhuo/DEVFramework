@tool
class_name TownRingStep extends TownStepDef
## 边界环路


func apply(ctx: TownGenContext) -> void:
	var def := ctx.def
	var roads := ctx.layout.roads_grid
	var bounds := Rect2i(); var first := true
	for y in roads.height:
		for x in roads.width:
			if roads.get_cell(x, y, 0) != 0:
				if first: bounds = Rect2i(x, y, 1, 1); first = false
				else: bounds = bounds.expand(Vector2i(x, y))
	if first: return
	var r := bounds.grow(2).intersection(Rect2i(0, 0, roads.width, roads.height))
	if r.size.x < 4 or r.size.y < 4: return
	for x in range(r.position.x, r.end.x):
		_mark(def, roads, Vector2i(x, r.position.y))
		_mark(def, roads, Vector2i(x, r.end.y - 1))
	for y in range(r.position.y + 1, r.end.y - 1):
		_mark(def, roads, Vector2i(r.position.x, y))
		_mark(def, roads, Vector2i(r.end.x - 1, y))


func _mark(def: TownDef, roads: GeneratedGrid, p: Vector2i) -> void:
	if roads.get_cell(p.x, p.y, 0) != 0: return
	roads.set_cell(p.x, p.y, def.road_ring_value)
