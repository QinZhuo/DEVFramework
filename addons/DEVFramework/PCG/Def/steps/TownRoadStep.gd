@tool
class_name TownRoadStep extends TownStepDef
## S2 道路网 — 主街(坡度A*) + 次街扰动生长

@export_range(1, 4, 1) var main_width := 2
@export_range(3, 24, 1) var spacing_min := 5
@export_range(4, 32, 1) var spacing_max := 9
@export_range(6, 128, 1) var secondary_max_len := 56
@export_range(0.0, 2.0, 0.05) var main_jitter := 0.4
@export_range(0.0, 4.0, 0.05) var slope_cost_k := 1.5


func apply(ctx: TownGenContext) -> void:
	var def: TownDef = ctx.def
	var layout := ctx.layout
	var hm := ctx.heightmap
	var rng := ctx.next_rng()
	var roads := layout.roads_grid
	var w := roads.width
	var h := roads.height

	# 主街: 选址→边缘陆地枢纽
	var hub := _hub(def, hm, ctx.main_cells, rng)
	var main_path := _astar(def, hm, roads, Vector2(ctx.site), Vector2(hub), rng, main_jitter)
	if main_path.is_empty():
		main_path = _l_path(Vector2(ctx.site), Vector2(hub), rng)

	_stamp(roads, main_path, def.main_width, def.road_main_value, hm, def.sea_level, def.bridge_value)
	layout.road_nodes.append(Vector2(ctx.site))
	layout.road_nodes.append(Vector2(hub))
	layout.road_edges.append({"a": 0, "b": 1})

	# 次街生长
	var sp := rng.randi_range(maxi(3, spacing_min), maxi(4, spacing_max))
	var i := sp
	while i < main_path.size() - 1:
		var p := main_path[i]
		var nxt := main_path[mini(i + 1, main_path.size() - 1)]
		var perp := Vector2(-(nxt.y - p.y), nxt.x - p.x).normalized()
		for side in [-1.0, 1.0]:
			if rng.randf() < 0.1:
				continue
			_grow(def, roads, p + perp * side * 2.0, perp * side,
				def.road_sec_value, secondary_max_len, rng)
		i += sp


func _hub(def: TownDef, hm: HeightMap, cells: PackedInt32Array, rng: RandomNumberGenerator) -> Vector2i:
	if hm != null and not cells.is_empty():
		var w := def.width
		var best_e := INF
		var best_cands: Array = []
		for idx in cells:
			var x: int = int(idx) % w
			var y: int = int(idx) / w
			var e := float(mini(mini(x, w - 1 - x), mini(y, def.height - 1 - y)))
			if e < best_e:
				best_e = e; best_cands = [[x, y]]
			elif e == best_e and best_cands.size() < 8:
				best_cands.append([x, y])
		if not best_cands.is_empty():
			var pk: Array = best_cands[rng.randi_range(0, best_cands.size() - 1)]
			return Vector2i(int(pk[0]), int(pk[1]))
	match rng.randi_range(0, 3):
		0: return Vector2i(rng.randi_range(1, def.width - 2), 0)
		1: return Vector2i(def.width - 1, rng.randi_range(1, def.height - 2))
		2: return Vector2i(rng.randi_range(1, def.width - 2), def.height - 1)
	return Vector2i(0, rng.randi_range(1, def.height - 2))


func _astar(def: TownDef, hm: HeightMap, roads: GeneratedGrid,
		a: Vector2, b: Vector2, rng: RandomNumberGenerator, jitter: float) -> PackedVector2Array:
	var w := roads.width
	var h := roads.height
	var start := Vector2i(clampi(int(a.x), 0, w - 1), clampi(int(a.y), 0, h - 1))
	var goal := Vector2i(clampi(int(b.x), 0, w - 1), clampi(int(b.y), 0, h - 1))
	var n := w * h
	var g_arr := PackedFloat64Array(); g_arr.resize(n); g_arr.fill(INF)
	var prev := PackedInt32Array(); prev.resize(n); prev.fill(-1)
	var closed := PackedByteArray(); closed.resize(n)
	var open_keys := PackedFloat64Array()
	var open_vals := PackedInt32Array()
	var si := start.y * w + start.x; var gi := goal.y * w + goal.x
	g_arr[si] = 0.0
	open_keys.append(float(absi(start.x - goal.x) + absi(start.y - goal.y)))
	open_vals.append(si)
	while open_keys.size() > 0:
		var mi := 0
		for k in range(1, open_keys.size()):
			if open_keys[k] < open_keys[mi]: mi = k
		var cur: int = open_vals[mi]
		open_keys.remove_at(mi); open_vals.remove_at(mi)
		if closed[cur] == 1: continue
		closed[cur] = 1
		if cur == gi: break
		var cx := cur % w; var cy := cur / w
		for d in [Vector2i(0,-1), Vector2i(1,0), Vector2i(0,1), Vector2i(-1,0)]:
			var nx: int = cx + d.x; var ny: int = cy + d.y
			if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
			var ni: int = ny * w + nx
			if closed[ni] == 1: continue
			var cost := 1.0 + slope_cost_k * pow(absf(_h(hm, nx, ny) - _h(hm, cx, cy)), 2.0)
			if roads.get_cell(nx, ny, 0) != 0: cost *= 0.4
			var ng: float = g_arr[cur] + cost
			if ng < g_arr[ni]:
				g_arr[ni] = ng; prev[ni] = cur
				open_keys.append(ng + float(absi(nx - goal.x) + absi(ny - goal.y))); open_vals.append(ni)
	var out := PackedVector2Array()
	var ci := gi
	while ci >= 0:
		out.append(Vector2(ci % w, ci / w)); ci = prev[ci]
	out.reverse()
	return out


func _stamp(roads: GeneratedGrid, path: PackedVector2Array, width: int, value: int,
		hm: HeightMap, sea: float, bridge_v: int) -> void:
	var hw := (width - 1) / 2
	for p in path:
		var px := int(p.x); var py := int(p.y)
		for dy in range(-hw, width - hw):
			for dx in range(-hw, width - hw):
				var x := px + dx; var y := py + dy
				if not roads.in_bounds(x, y): continue
				var v := value
				if hm != null and hm.get_height(x, y, 1.0) < sea: v = bridge_v
				roads.set_cell(x, y, v)


func _grow(def: TownDef, roads: GeneratedGrid, start: Vector2, dir: Vector2,
		value: int, max_len: int, rng: RandomNumberGenerator) -> void:
	var cur := Vector2i(int(round(start.x)), int(round(start.y)))
	if not roads.in_bounds(cur.x, cur.y): return
	var d := _dom(dir)
	for _s in max_len:
		if not roads.in_bounds(cur.x, cur.y): return
		if roads.get_cell(cur.x, cur.y, 0) != 0 and _s > 0: return
		roads.set_cell(cur.x, cur.y, value)
		var nd := d
		if rng.randf() < 0.3:
			nd = TownGenTool.turn_left(d) if rng.randf() < 0.5 else TownGenTool.turn_right(d)
		var np := cur + nd
		if not roads.in_bounds(np.x, np.y):
			nd = TownGenTool.turn_left(d) if rng.randf() < 0.5 else TownGenTool.turn_right(d)
			np = cur + nd
			if not roads.in_bounds(np.x, np.y): return
		d = nd; cur = np


func _dom(v: Vector2) -> Vector2i:
	if absf(v.x) > absf(v.y): return Vector2i(signi(int(v.x)), 0)
	return Vector2i(0, signi(int(v.y)))


func _l_path(a: Vector2, b: Vector2, rng: RandomNumberGenerator) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var x := int(a.x); var y := int(a.y)
	pts.append(a)
	if rng.randf() < 0.5:
		while x != int(b.x): x += signi(int(b.x)-x); pts.append(Vector2(x,y))
		while y != int(b.y): y += signi(int(b.y)-y); pts.append(Vector2(x,y))
	else:
		while y != int(b.y): y += signi(int(b.y)-y); pts.append(Vector2(x,y))
		while x != int(b.x): x += signi(int(b.x)-x); pts.append(Vector2(x,y))
	return pts


func _h(hm: HeightMap, x: int, y: int) -> float:
	if hm == null: return 0.5
	return hm.get_height(x, y, 0.5)
