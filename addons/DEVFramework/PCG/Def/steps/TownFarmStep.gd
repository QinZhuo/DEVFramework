@tool
class_name TownFarmStep extends TownStepDef
## 农田 — 距选址超过最小距离的连片空地转农田

@export_range(4, 64, 1) var farm_min_dist := 14
@export_range(8, 512, 4) var farm_min_area := 60


func apply(ctx: TownGenContext) -> void:
	var def: TownDef = ctx.def
	var layout := ctx.layout
	var roads := layout.roads_grid
	layout.farms.clear()
	var cand := {}
	for y in roads.height:
		for x in roads.width:
			var idx: int = y * roads.width + x
			if roads.get_cell(x, y, 0) != 0: continue
			if Vector2(x, y).distance_to(Vector2(ctx.site)) >= farm_min_dist:
				cand[idx] = true
	var visited := {}
	for idx in cand:
		if visited.has(int(idx)): continue
		var comp := PackedInt32Array()
		var stack: Array[int] = [int(idx)]
		visited[int(idx)] = true
		while not stack.is_empty():
			var cur: int = stack.pop_back()
			comp.append(cur)
			var cx: int = cur % roads.width; var cy: int = cur / roads.width
			for d in [Vector2i(0,-1), Vector2i(1,0), Vector2i(0,1), Vector2i(-1,0)]:
				var ni: int = (cy + d.y) * roads.width + (cx + d.x)
				if cand.has(ni) and not visited.has(ni):
					visited[ni] = true; stack.append(ni)
		if comp.size() >= farm_min_area:
			layout.farms.append(comp)
