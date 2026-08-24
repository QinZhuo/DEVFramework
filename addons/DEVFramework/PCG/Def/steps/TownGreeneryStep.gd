@tool
class_name TownGreeneryStep extends TownStepDef
## 绿化散布 — 城镇空地泊松式树木 + 行道树

@export_range(0, 600, 5) var tree_count := 140
@export_range(1.0, 8.0, 0.5) var tree_min_distance := 2.5
@export_range(0, 16, 1) var street_tree_spacing := 5


func apply(ctx: TownGenContext) -> void:
	var def: TownDef = ctx.def
	var layout := ctx.layout
	var roads := layout.roads_grid
	var rng := ctx.next_rng()
	if tree_count <= 0: return
	# 行道树：主街两侧间隔
	if street_tree_spacing > 0:
		var walk := 0
		for y in roads.height:
			for x in roads.width:
				if roads.get_cell(x, y, -1) == def.road_main_value:
					walk += 1
					if walk % street_tree_spacing == 0:
						for d in [Vector2i(0,-1), Vector2i(1,0), Vector2i(0,1), Vector2i(-1,0)]:
							var nx: int = x + d.x; var ny: int = y + d.y
							if roads.in_bounds(nx, ny) and roads.get_cell(nx, ny, 0) == 0:
								layout.trees.append(Vector2i(nx, ny))
								break
	# 空地散布
	var min_d2: float = tree_min_distance * tree_min_distance
	var placed := PackedVector3Array()
	for t in layout.trees: placed.append(Vector3(t.x, t.y, 0))
	var attempts := maxi(tree_count * 8, 400)
	while layout.trees.size() < tree_count and attempts > 0:
		attempts -= 1
		var x := rng.randi_range(1, roads.width - 2)
		var y := rng.randi_range(1, roads.height - 2)
		if roads.get_cell(x, y, 0) != 0: continue
		var ok := true
		for p in placed:
			if Vector2(p.x, p.y).distance_to(Vector2(x, y)) < tree_min_distance:
				ok = false; break
		if not ok: continue
		layout.trees.append(Vector2i(x, y))
