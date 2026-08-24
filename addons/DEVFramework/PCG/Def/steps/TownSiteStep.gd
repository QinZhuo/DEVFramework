@tool
class_name TownSiteStep extends TownStepDef
## S1 选址 — 最大陆地连通域内评分选址（平坦度/近水带宽/陆地占比）

@export_range(4, 128, 1) var site_candidates := 32
@export_range(2, 32, 1) var site_radius := 8
@export_range(0, 32, 1) var water_band_min := 3
@export_range(4, 96, 1) var water_band_max := 24


func apply(ctx: TownGenContext) -> void:
	var def := ctx.def
	var hm := ctx.heightmap
	var fallback := Vector2i(def.width / 2, def.height / 2)
	if hm == null or hm.width <= 0:
		ctx.site = fallback
		ctx.site_score = 1.0
		return
	var land := GeneratedGrid.create(hm.width, hm.height, 0)
	for i in hm.heights.size():
		land.cells[i] = 1 if hm.heights[i] >= def.sea_level else 0
	var comps := land.components(1)
	if comps.is_empty():
		ctx.site = fallback
		ctx.site_score = 0.0
		return
	var main := comps[0]
	for c in comps:
		if c.size() > main.size():
			main = c
	var rng := ctx.next_rng()
	var water_dist := _water_distance(land)
	var best_idx: int = main[0]
	var best_score := -INF
	for _k in maxi(1, site_candidates):
		var idx: int = main[rng.randi_range(0, main.size() - 1)]
		var s := _score(def, hm, water_dist, idx % land.width, idx / land.width)
		if s > best_score:
			best_score = s
			best_idx = idx
	ctx.site = Vector2i(best_idx % land.width, best_idx / land.width)
	ctx.site_score = clampf(best_score, 0.0, 1.0)
	ctx.main_cells = main


func _score(step_def: TownDef, hm: HeightMap, wd: PackedFloat32Array, cx: int, cy: int) -> float:
	var r := site_radius
	var sl := 0.0
	var sn := 0
	var ln := 0
	var tot := 0
	for dy in range(-r, r + 1, 2):
		for dx in range(-r, r + 1, 2):
			var x := cx + dx
			var y := cy + dy
			if not hm.in_bounds(x, y):
				continue
			tot += 1
			sl += hm.slope(x, y)
			sn += 1
			if hm.heights[y * hm.width + x] >= step_def.sea_level:
				ln += 1
	var flat := clampf(1.0 - (sl / maxf(1.0, sn)) / 0.08, 0.0, 1.0)
	var ratio := float(ln) / maxf(1, tot)
	var d := wd[cy * hm.width + cx]
	var ws := 1.0
	if d < INF:
		if d < water_band_min:
			ws = d / maxf(1.0, float(water_band_min))
		elif d > water_band_max:
			ws = clampf(1.0 - (d - water_band_max) / maxf(8.0, float(water_band_max)), 0.0, 1.0)
	return 0.45 * flat + 0.35 * ws + 0.20 * ratio


static func _water_distance(land: GeneratedGrid) -> PackedFloat32Array:
	var dist := PackedFloat32Array()
	dist.resize(land.cells.size())
	dist.fill(INF)
	var queue := PackedInt32Array()
	for i in land.cells.size():
		if land.cells[i] == 0:
			dist[i] = 0.0
			queue.append(i)
	var head := 0
	while head < queue.size():
		var cur: int = queue[head]
		head += 1
		var cx := cur % land.width
		var cy := cur / land.width
		for d in [Vector2i(0,-1), Vector2i(1,0), Vector2i(0,1), Vector2i(-1,0)]:
			var nx: int = cx + d.x
			var ny: int = cy + d.y
			if not land.in_bounds(nx, ny):
				continue
			var ni: int = ny * land.width + nx
			if dist[ni] > dist[cur] + 1.0:
				dist[ni] = dist[cur] + 1.0
				queue.append(ni)
	return dist
