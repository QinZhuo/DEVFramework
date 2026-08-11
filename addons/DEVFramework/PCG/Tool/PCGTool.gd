@tool
## PCG 统一入口 — 随机 / 噪声 / 网格 / 散布 / 内容 / 管线
##
## 设计要点：
##   - 一切生成从 seed 派生，同一 Def + 同一种子必可复现
##   - 管线中每个生成器使用独立派生的 RNG（derive_seed），互不干扰、顺序稳定
##   - 只包装 Godot 内置能力（FastNoiseLite 等），不自研可复用底层
class_name PCGTool

## —— 随机 ——

## 创建带种子的随机源
static func make_rng(seed: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	return rng

## 从基础种子派生独立子种子（管线中不同生成器用不同 slot，保证可复现且互不干扰）
static func derive_seed(base: int, slot: int) -> int:
	return (base ^ (slot * 0x9E3779B1)) & 0x7FFFFFFF

## —— 噪声 ——

## 把噪声层渲染成灰度图（用于预览 / 纹理）
static func noise_image(layer: NoiseLayerDef, width: int, height: int, seed := 0) -> Image:
	var img := Image.create(width, height, false, Image.FORMAT_RGB8)
	var noise: FastNoiseLite = layer.build_noise(seed)
	for y in height:
		for x in width:
			var v := layer.sample(noise, x, y)
			img.set_pixel(x, y, Color(v, v, v))
	return img

## —— 网格 ——

static func generate_grid(def: GridGenDef, rng: RandomNumberGenerator, fixed: Dictionary = {}) -> GeneratedGrid:
	var grid := GeneratedGrid.create(def.width, def.height, def.empty_value)
	match def.type:
		GridGenDef.Type.NOISE_TERRAIN:
			_gen_noise_terrain(grid, def, rng)
		GridGenDef.Type.CELLULAR:
			_gen_cellular(grid, def, rng)
		GridGenDef.Type.MAZE:
			_gen_maze(grid, def, rng)
		GridGenDef.Type.RANDOM_WALK:
			_gen_random_walk(grid, def, rng)
		GridGenDef.Type.BSP_ROOMS:
			_gen_bsp_rooms(grid, def, rng)
		GridGenDef.Type.WFC:
			_gen_wfc(grid, def, rng, fixed)
	return grid

## 后台线程生成网格（大图不卡主线程；GeneratedGrid 是纯数据，线程安全）
static func generate_grid_async(def: GridGenDef, seed: int) -> GeneratedGrid:
	var grid: GeneratedGrid = await AsyncTool.thread_call(func() -> GeneratedGrid:
		return generate_grid(def, make_rng(seed))
	)
	return grid

## 把栅格渲染成图（palette: 格值 → 颜色）
static func grid_to_image(grid: GeneratedGrid, palette: Dictionary = {}) -> Image:
	var img := Image.create(grid.width, grid.height, false, Image.FORMAT_RGB8)
	for i in grid.cells.size():
		img.set_pixel(i % grid.width, i / grid.width, palette.get(grid.cells[i], Color.BLACK))
	return img

## —— 生物群系 ——

## 采样多层噪声生成生物群系图（每个格子 = biomes 索引）
static func generate_biome(def: BiomeMapDef, rng: RandomNumberGenerator) -> BiomeMap:
	var result := BiomeMap.new()
	result.width = def.width
	result.height = def.height
	result.biomes = def.biomes
	result.indices.resize(def.width * def.height)
	var elev: FastNoiseLite = def.elevation_layer.build_noise(rng.seed) if def.elevation_layer else null
	var moist: FastNoiseLite = def.moisture_layer.build_noise(rng.seed) if def.moisture_layer else null
	var temp: FastNoiseLite = def.temperature_layer.build_noise(rng.seed) if def.temperature_layer else null
	for y in def.height:
		for x in def.width:
			var h := def.elevation_layer.sample(elev, x, y) if elev else 0.5
			var m := def.moisture_layer.sample(moist, x, y) if moist else 0.5
			var t := def.temperature_layer.sample(temp, x, y) if temp else 0.5
			result.indices[y * def.width + x] = _biome_pick(def.biomes, h, m, t)
	return result

## 按群系颜色渲染成图
static func biome_to_image(biome_map: BiomeMap) -> Image:
	var img := Image.create(biome_map.width, biome_map.height, false, Image.FORMAT_RGB8)
	for i in biome_map.indices.size():
		var idx := biome_map.indices[i]
		var c := biome_map.biomes[idx].color if idx >= 0 and idx < biome_map.biomes.size() else Color.BLACK
		img.set_pixel(i % biome_map.width, i / biome_map.width, c)
	return img

## 按 高度/湿度/温度 选群系（顺序优先，兜底返回最后一个）
static func _biome_pick(biomes: Array[BiomeEntryDef], h: float, m: float, t: float) -> int:
	for i in biomes.size():
		if biomes[i] and biomes[i].matches(h, m, t):
			return i
	return biomes.size() - 1

## —— 散布 ——

static func place(def: PlacementDef, rng: RandomNumberGenerator) -> PackedVector2Array:
	match def.mode:
		PlacementDef.Mode.POISSON_DISK:
			return _place_poisson(def, rng)
		PlacementDef.Mode.JITTER_GRID:
			return _place_jitter_grid(def, rng)
		PlacementDef.Mode.RANDOM_UNIFORM:
			return _place_random(def, rng)
	return PackedVector2Array()

## 把点集渲染成图（用于预览）
static func points_to_image(points: PackedVector2Array, image_size: Vector2i, color := Color.WHITE, bg := Color(0.1, 0.12, 0.14), point_radius := 1) -> Image:
	var img := Image.create(image_size.x, image_size.y, false, Image.FORMAT_RGB8)
	img.fill(bg)
	for p in points:
		var px := int(p.x)
		var py := int(p.y)
		for dy in range(-point_radius, point_radius + 1):
			for dx in range(-point_radius, point_radius + 1):
				var x := px + dx
				var y := py + dy
				if x >= 0 and y >= 0 and x < image_size.x and y < image_size.y:
					img.set_pixel(x, y, color)
	return img

## —— 内容 ——

static func generate_content(def: ContentGenDef, rng: RandomNumberGenerator) -> Array:
	match def.mode:
		ContentGenDef.Mode.WEIGHTED:
			var out: Array = []
			for i in def.count:
				var e := pick_weighted(rng, def.entries)
				if e:
					out.append(e)
			return out
		ContentGenDef.Mode.NAME:
			var out: Array = []
			for i in def.count:
				out.append(generate_name(def, rng))
			return out
		ContentGenDef.Mode.MARKOV:
			var out: Array = []
			for i in def.count:
				out.append(generate_markov(def, rng))
			return out
		ContentGenDef.Mode.AFFIX:
			var out: Array = []
			for i in def.count:
				out.append(generate_affix(def, rng))
			return out
	return []

## 词缀组合（基础词 + 随机前缀/后缀；未配置时用默认表）
static func generate_affix(def: ContentGenDef, rng: RandomNumberGenerator) -> String:
	var bases := def.affix_bases
	var prefixes := def.affix_prefixes
	var suffixes := def.affix_suffixes
	if bases.is_empty():
		bases = PackedStringArray(["长剑", "法杖", "弓", "盾牌", "护符", "戒指"])
	if prefixes.is_empty():
		prefixes = PackedStringArray(["锋利", "燃烧", "冰霜", "雷霆", "暗影", "神圣", "剧毒", "迅捷"])
	if suffixes.is_empty():
		suffixes = PackedStringArray(["之贪婪", "之毁灭", "之守护", "之祝福", "之诅咒", "之狂怒"])
	var out := bases[rng.randi_range(0, bases.size() - 1)]
	if not prefixes.is_empty() and rng.randf() < def.affix_prefix_chance:
		out = prefixes[rng.randi_range(0, prefixes.size() - 1)] + out
	if not suffixes.is_empty() and rng.randf() < def.affix_suffix_chance:
		out += suffixes[rng.randi_range(0, suffixes.size() - 1)]
	return out

## 加权抽取一个条目（按 weight 概率）
static func pick_weighted(rng: RandomNumberGenerator, entries: Array[ContentEntryDef]) -> ContentEntryDef:
	var total := 0.0
	for e in entries:
		total += maxf(e.weight, 0.0)
	if total <= 0.0:
		return entries[0] if not entries.is_empty() else null
	var r := rng.randf() * total
	for e in entries:
		r -= maxf(e.weight, 0.0)
		if r <= 0.0:
			return e
	return entries[entries.size() - 1]

## 名字合成（前缀 + 后缀；未配置时用默认音节表）
static func generate_name(def: ContentGenDef, rng: RandomNumberGenerator) -> String:
	var prefixes := def.prefixes
	var suffixes := def.suffixes
	if prefixes.is_empty():
		prefixes = PackedStringArray(["银", "暗", "星", "风", "霜", "雷", "影", "雾", "血", "岩", "火", "冰"])
	if suffixes.is_empty():
		suffixes = PackedStringArray(["之刃", "之心", "之歌", "之眼", "之翼", "之语", "之环", "之王", "之印", "之冠"])
	return prefixes[rng.randi_range(0, prefixes.size() - 1)] + suffixes[rng.randi_range(0, suffixes.size() - 1)]

## 词级马尔可夫文本（语料按空格分词）
static func generate_markov(def: ContentGenDef, rng: RandomNumberGenerator) -> String:
	var words: Array[String] = []
	for sentence in def.corpus:
		for w in String(sentence).split(" "):
			if not w.is_empty():
				words.append(w)
	if words.is_empty():
		return ""
	if def.markov_order >= words.size():
		return " ".join(words)
	var table := {}  # PackedStringArray(前缀) → Array(后继词)
	for i in range(words.size() - def.markov_order):
		var key := PackedStringArray()
		for j in def.markov_order:
			key.append(words[i + j])
		table.get_or_add(key, []).append(words[i + def.markov_order])
	var keys: Array = table.keys()
	# 从训练好的前缀中随机起始，保证有后继
	var key: PackedStringArray = keys[rng.randi_range(0, keys.size() - 1)]
	var out: Array[String] = []
	for i in def.markov_words:
		var nexts: Variant = table.get(key)
		if nexts == null or (nexts as Array).is_empty():
			break
		var w: String = (nexts as Array)[rng.randi_range(0, nexts.size() - 1)]
		out.append(w)
		key = key.slice(1)
		key.append(w)
	return " ".join(out)

## —— 管线 ——

## 执行 PCGDef 管线，返回 output 字典（key → 生成结果）
static func generate(def: PCGDef, seed := 0) -> Dictionary:
	var base := seed if seed != 0 else def.seed
	var ctx := PCGContext.new()
	ctx.seed = base
	var slot := 0
	for g in def.generators:
		if g == null or not g.enabled:
			continue
		ctx.rng = make_rng(derive_seed(base, slot))
		g.generate(ctx)
		slot += 1
	return ctx.output

## —— 网格算法实现 ——

static func _gen_noise_terrain(grid: GeneratedGrid, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	var noise: FastNoiseLite = def.noise_layer.build_noise(rng.seed) if def.noise_layer else null
	for y in grid.height:
		for x in grid.width:
			var solid := false
			if noise:
				solid = def.noise_layer.sample(noise, x, y) >= def.threshold
			else:
				solid = rng.randf() < def.threshold
			if solid:
				grid.set_cell(x, y, def.solid_value)

static func _gen_cellular(grid: GeneratedGrid, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	for i in grid.cells.size():
		grid.cells[i] = def.solid_value if rng.randf() < def.cave_ratio else def.empty_value
	for _pass in def.smooth_passes:
		var new_cells := grid.cells.duplicate()
		for y in grid.height:
			for x in grid.width:
				var walls := 0
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if dx == 0 and dy == 0:
							continue
						var ov := grid.get_cell(x + dx, y + dy, def.solid_value if def.border_solid else def.empty_value)
						if ov == def.solid_value:
							walls += 1
				new_cells[y * grid.width + x] = def.solid_value if walls >= 5 else def.empty_value
		grid.cells = new_cells

static func _gen_maze(grid: GeneratedGrid, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	grid.fill(def.solid_value)
	var dirs: Array[Vector2i] = [Vector2i(0, 2), Vector2i(2, 0), Vector2i(0, -2), Vector2i(-2, 0)]
	var in_tree := {}
	var added := {}
	var active: Array[Vector2i] = []
	var start := Vector2i(1, 1)
	grid.set_cell(start.x, start.y, def.empty_value)
	in_tree[_key(start)] = true
	# 起点视为已生成，把其候选节点加入 frontier
	for d in dirs:
		var nb := start + d
		if _inside(grid, nb) and not added.has(_key(nb)):
			active.append(nb)
			added[_key(nb)] = true
	while not active.is_empty():
		var idx := rng.randi_range(0, active.size() - 1)
		var node: Vector2i = active[idx]
		active.remove_at(idx)
		if in_tree.has(_key(node)):
			continue
		var connected: Array[Vector2i] = []
		for d in dirs:
			var nb := node + d
			if _inside(grid, nb) and in_tree.has(_key(nb)):
				connected.append(nb)
		if connected.is_empty():
			continue
		var target: Vector2i = connected[rng.randi_range(0, connected.size() - 1)]
		var mid := (node + target) / 2
		grid.set_cell(mid.x, mid.y, def.empty_value)
		grid.set_cell(node.x, node.y, def.empty_value)
		in_tree[_key(node)] = true
		for d in dirs:
			var nb2 := node + d
			if _inside(grid, nb2) and not added.has(_key(nb2)):
				active.append(nb2)
				added[_key(nb2)] = true
	# 环路度：随机打通内部墙（两侧都是通道的墙）
	if def.maze_loopiness > 0.0:
		var extra := int(grid.width * grid.height * def.maze_loopiness * 0.02)
		for i in extra:
			var x := rng.randi_range(1, grid.width - 2)
			var y := rng.randi_range(1, grid.height - 2)
			if grid.get_cell(x, y) != def.solid_value:
				continue
			var l := grid.get_cell(x - 1, y) == def.empty_value
			var r := grid.get_cell(x + 1, y) == def.empty_value
			var u := grid.get_cell(x, y - 1) == def.empty_value
			var d := grid.get_cell(x, y + 1) == def.empty_value
			if (l and r) or (u and d):
				grid.set_cell(x, y, def.empty_value)

static func _gen_random_walk(grid: GeneratedGrid, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	grid.fill(def.solid_value)
	var x := grid.width / 2 if def.walk_start_center else rng.randi_range(1, maxi(1, grid.width - 2))
	var y := grid.height / 2 if def.walk_start_center else rng.randi_range(1, maxi(1, grid.height - 2))
	grid.set_cell(x, y, def.empty_value)
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for i in def.walk_steps:
		var d: Vector2i = dirs[rng.randi_range(0, 3)]
		x = clampi(x + d.x, 1, grid.width - 2)
		y = clampi(y + d.y, 1, grid.height - 2)
		grid.set_cell(x, y, def.empty_value)

class _BSPLeaf:
	var rect := Rect2i()
	var left: _BSPLeaf = null
	var right: _BSPLeaf = null
	var room := Rect2i()

static func _gen_bsp_rooms(grid: GeneratedGrid, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	grid.fill(def.solid_value)
	var root := _BSPLeaf.new()
	root.rect = Rect2i(0, 0, grid.width, grid.height)
	_split(root, def.bsp_depth, def, rng)
	_make_rooms(root, grid, def, rng)

static func _split(leaf: _BSPLeaf, depth: int, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	if depth <= 0:
		return
	var w := leaf.rect.size.x
	var h := leaf.rect.size.y
	if w < def.room_min_size * 3 and h < def.room_min_size * 3:
		return
	var horizontal := false
	if h > w * 1.2:
		horizontal = true
	elif w > h * 1.2:
		horizontal = false
	else:
		horizontal = rng.randf() < 0.5
	var len := h if horizontal else w
	var min_part := def.room_min_size + 1
	var max_part := len - min_part
	if max_part <= min_part:
		return
	var pos := rng.randi_range(min_part, max_part)
	var left := _BSPLeaf.new()
	var right := _BSPLeaf.new()
	if horizontal:
		left.rect = Rect2i(leaf.rect.position, Vector2i(w, pos))
		right.rect = Rect2i(leaf.rect.position + Vector2i(0, pos), Vector2i(w, h - pos))
	else:
		left.rect = Rect2i(leaf.rect.position, Vector2i(pos, h))
		right.rect = Rect2i(leaf.rect.position + Vector2i(pos, 0), Vector2i(w - pos, h))
	leaf.left = left
	leaf.right = right
	_split(left, depth - 1, def, rng)
	_split(right, depth - 1, def, rng)

static func _make_rooms(leaf: _BSPLeaf, grid: GeneratedGrid, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	if leaf == null:
		return
	if leaf.left == null and leaf.right == null:
		var rw := mini(def.room_max_size, leaf.rect.size.x - 2)
		var rh := mini(def.room_max_size, leaf.rect.size.y - 2)
		rw = maxi(rng.randi_range(def.room_min_size, rw), 1)
		rh = maxi(rng.randi_range(def.room_min_size, rh), 1)
		var rx := leaf.rect.position.x + rng.randi_range(1, maxi(1, leaf.rect.size.x - rw - 1))
		var ry := leaf.rect.position.y + rng.randi_range(1, maxi(1, leaf.rect.size.y - rh - 1))
		leaf.room = Rect2i(rx, ry, rw, rh)
		_fill_room(grid, leaf.room, def)
	else:
		_make_rooms(leaf.left, grid, def, rng)
		_make_rooms(leaf.right, grid, def, rng)
		# 内部节点用左右子树中的任意房间作为代表连接，保证全部房间连通
		var ra := _find_room(leaf.left)
		var rb := _find_room(leaf.right)
		if ra.size != Vector2i.ZERO and rb.size != Vector2i.ZERO:
			_carve_path(grid, ra.get_center(), rb.get_center(), def, rng)

## 递归找子树内任意房间（内部节点自身没有 room）
static func _find_room(leaf: _BSPLeaf) -> Rect2i:
	if leaf == null:
		return Rect2i()
	if leaf.room.size != Vector2i.ZERO:
		return leaf.room
	var r := _find_room(leaf.left)
	if r.size != Vector2i.ZERO:
		return r
	return _find_room(leaf.right)

static func _fill_room(grid: GeneratedGrid, room: Rect2i, def: GridGenDef) -> void:
	for y in range(room.position.y, room.end.y):
		for x in range(room.position.x, room.end.x):
			grid.set_cell(x, y, def.empty_value)

static func _carve_path(grid: GeneratedGrid, a: Vector2i, b: Vector2i, def: GridGenDef, rng: RandomNumberGenerator) -> void:
	if rng.randf() < 0.5:
		_carve_line(grid, a, Vector2i(b.x, a.y), def)
		_carve_line(grid, Vector2i(b.x, a.y), b, def)
	else:
		_carve_line(grid, a, Vector2i(a.x, b.y), def)
		_carve_line(grid, Vector2i(a.x, b.y), b, def)

static func _carve_line(grid: GeneratedGrid, a: Vector2i, b: Vector2i, def: GridGenDef) -> void:
	var x := a.x
	var y := a.y
	while x != b.x:
		_carve_cell(grid, x, y, def)
		x += signi(b.x - a.x)
	while y != b.y:
		_carve_cell(grid, x, y, def)
		y += signi(b.y - a.y)
	_carve_cell(grid, b.x, b.y, def)

static func _carve_cell(grid: GeneratedGrid, x: int, y: int, def: GridGenDef) -> void:
	var hw := (def.corridor_width - 1) / 2
	var range_w := def.corridor_width - hw
	for dy in range(-hw, range_w):
		for dx in range(-hw, range_w):
			grid.set_cell(x + dx, y + dy, def.empty_value)

static func _key(p: Vector2i) -> String:
	return "%d,%d" % [p.x, p.y]

static func _inside(grid: GeneratedGrid, p: Vector2i) -> bool:
	return p.x >= 0 and p.x < grid.width and p.y >= 0 and p.y < grid.height

## —— 散布算法实现 ——

static func _place_poisson(def: PlacementDef, rng: RandomNumberGenerator) -> PackedVector2Array:
	var r := maxf(def.min_distance, 0.001)
	var cell := r / sqrt(2.0)
	var gw := ceili(def.region_size.x / cell)
	var gh := ceili(def.region_size.y / cell)
	var occupancy := {}  # Vector2i → Vector2
	var result := PackedVector2Array()
	var active := PackedVector2Array()
	var start := Vector2(rng.randf_range(0.0, def.region_size.x), rng.randf_range(0.0, def.region_size.y))
	result.append(start)
	active.append(start)
	occupancy[Vector2i(int(start.x / cell), int(start.y / cell))] = start
	while not active.is_empty() and result.size() < def.count:
		var idx := rng.randi_range(0, active.size() - 1)
		var center: Vector2 = active[idx]
		var placed := false
		for i in def.max_attempts:
			var ang := rng.randf() * TAU
			var dist := rng.randf_range(r, r * 2.0)
			var cand := center + Vector2(cos(ang), sin(ang)) * dist
			if cand.x < 0.0 or cand.y < 0.0 or cand.x >= def.region_size.x or cand.y >= def.region_size.y:
				continue
			var gi := Vector2i(int(cand.x / cell), int(cand.y / cell))
			if not _poisson_ok(occupancy, gw, gh, gi, cell, r, cand):
				continue
			result.append(cand)
			active.append(cand)
			occupancy[gi] = cand
			placed = true
			break
		if not placed:
			active.remove_at(idx)
	return result

static func _poisson_ok(occupancy: Dictionary, gw: int, gh: int, gi: Vector2i, cell: float, r: float, cand: Vector2) -> bool:
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			var gx := gi.x + dx
			var gy := gi.y + dy
			if gx < 0 or gy < 0 or gx >= gw or gy >= gh:
				continue
			var other: Variant = occupancy.get(Vector2i(gx, gy))
			if other != null and (other as Vector2).distance_to(cand) < r:
				return false
	return true

static func _place_jitter_grid(def: PlacementDef, rng: RandomNumberGenerator) -> PackedVector2Array:
	var cols := maxi(1, ceili(sqrt(float(def.count) * def.region_size.x / maxf(def.region_size.y, 1.0))))
	var rows := maxi(1, ceili(float(def.count) / float(cols)))
	var cw := def.region_size.x / cols
	var ch := def.region_size.y / rows
	var out := PackedVector2Array()
	for i in cols:
		for j in rows:
			if out.size() >= def.count:
				break
			var base := Vector2(i * cw, j * ch)
			var jx := (rng.randf() - 0.5) * cw * def.jitter
			var jy := (rng.randf() - 0.5) * ch * def.jitter
			out.append(base + Vector2(cw, ch) * 0.5 + Vector2(jx, jy))
	return out

static func _place_random(def: PlacementDef, rng: RandomNumberGenerator) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in def.count:
		out.append(Vector2(rng.randf() * def.region_size.x, rng.randf() * def.region_size.y))
	return out

## —— WFC 算法实现（简单瓦片模型 + 固定格 / 回溯 / 重试） ——

## 每格候选集用 bitmask（瓦片索引位），波函数坍缩 = 选格 → 加权随机坍缩 → 邻接约束传播。
## fixed 支持 key 为 Vector2i / int(线性索引) / String("x,y")，value 为瓦片索引。
## 冲突时优先回溯到上一次观测重选；仍失败则整体重试（wfc_retries 次），全部失败降级随机填充。
static func _gen_wfc(grid: GeneratedGrid, def: GridGenDef, rng: RandomNumberGenerator, fixed: Dictionary = {}) -> void:
	var tiles := def.tile_set.tiles if def.tile_set else []
	var n := tiles.size()
	if n <= 0 or n >= 30:
		grid.fill(def.solid_value)
		return
	var cell_count := grid.width * grid.height
	# GDScript 版 WFC 选格是 O(n²)，大网格降级为加权随机填充并提示
	if cell_count > 20000:
		LogTool.warn("PCG", "WFC 网格过大(%d 格)，已降级为加权随机填充" % cell_count)
		for i in cell_count:
			grid.cells[i] = _wfc_weighted_choice(tiles, _wfc_bits((1 << n) - 1), rng)
		return
	for retry in def.wfc_retries + 1:
		if _wfc_generate_pass(grid, def, rng, fixed, cell_count, n):
			return
		LogTool.warn("PCG", "WFC 生成冲突，重试 %d/%d" % [retry + 1, def.wfc_retries])
	LogTool.warn("PCG", "WFC 重试耗尽，降级为加权随机填充")
	for i in cell_count:
		grid.cells[i] = _wfc_weighted_choice(tiles, _wfc_bits((1 << n) - 1), rng)

## 单遍 WFC：返回是否无矛盾（成功则写入 grid）
static func _wfc_generate_pass(grid: GeneratedGrid, def: GridGenDef, rng: RandomNumberGenerator, fixed: Dictionary, cell_count: int, n: int) -> bool:
	var tiles := def.tile_set.tiles
	var all_mask := (1 << n) - 1
	var wave := PackedInt32Array()
	wave.resize(cell_count)
	wave.fill(all_mask)
	var queue: Array[int] = []
	# 应用固定格（运行时 fixed 优先于资源内 wfc_fixed_cells）
	var merged := {}
	for key in def.wfc_fixed_cells:
		merged[key] = def.wfc_fixed_cells[key]
	for key in fixed:
		merged[key] = fixed[key]
	for key in merged:
		var idx := _wfc_fixed_index(grid, key)
		var tile_idx := int(merged[key])
		if idx >= 0 and tile_idx >= 0 and tile_idx < n:
			wave[idx] = 1 << tile_idx
			queue.append(idx)
	var propagations := 0
	propagations = _wfc_propagate(wave, grid, def, queue, propagations)
	# 观测-传播循环，冲突时回溯
	var history: Array = []  # 每项 {cell, wave_copy, bad}
	var backtracks := 0
	while true:
		var cell := _wfc_pick_lowest_entropy(wave)
		if cell == -1:
			break  # 全部坍缩完成
		var opts := _wfc_bits(wave[cell])
		if opts.is_empty():
			# 矛盾 → 回溯到上一次观测，排除已失败的瓦片
			if def.wfc_max_backtracks > 0 and backtracks < def.wfc_max_backtracks and not history.is_empty():
				backtracks += 1
				var h: Dictionary = history.pop_back()
				wave = h.wave_copy.duplicate()
				wave[h.cell] &= ~h.bad
				queue.append(h.cell)
				propagations = _wfc_propagate(wave, grid, def, queue, propagations)
				continue
			return false  # 无法回溯，本次失败
		var chosen := _wfc_weighted_choice(tiles, opts, rng)
		if def.wfc_max_backtracks > 0:
			history.append({"cell": cell, "wave_copy": wave.duplicate(), "bad": 1 << chosen})
		wave[cell] = 1 << chosen
		queue.append(cell)
		propagations = _wfc_propagate(wave, grid, def, queue, propagations)
	# 有任何矛盾格（候选为空）视为失败
	for i in cell_count:
		if wave[i] == 0:
			return false
	# 写入结果：单 bit 的格写瓦片索引，其余（失败格）写 solid_value
	for i in cell_count:
		var m := wave[i]
		if m != 0 and (m & (m - 1)) == 0:
			grid.cells[i] = _wfc_bit_index(m)
		else:
			grid.cells[i] = def.solid_value
	return true

## 解析固定格 key 为线性索引（支持 Vector2i / int / "x,y"）
static func _wfc_fixed_index(grid: GeneratedGrid, key) -> int:
	if key is Vector2i:
		return key.y * grid.width + key.x if grid.in_bounds(key.x, key.y) else -1
	if key is int:
		return key if key >= 0 and key < grid.width * grid.height else -1
	if key is String:
		var parts := String(key).split(",")
		if parts.size() == 2:
			var x := int(parts[0])
			var y := int(parts[1])
			if grid.in_bounds(x, y):
				return y * grid.width + x
	return -1

## 选候选数最少（>1）的格子（popcount 内联，避免函数调用开销）
static func _wfc_pick_lowest_entropy(wave: PackedInt32Array) -> int:
	var best := -1
	var best_count := 0x7FFFFFFF
	for i in wave.size():
		var v := wave[i]
		if v == 0:
			continue
		var cnt := 0
		var m := v
		while m:
			m &= m - 1
			cnt += 1
		if cnt > 1 and cnt < best_count:
			best_count = cnt
			best = i
	return best

## 邻接约束传播（BFS），返回累计传播次数
static func _wfc_propagate(wave: PackedInt32Array, grid: GeneratedGrid, def: GridGenDef, queue: Array[int], propagations: int) -> int:
	var tiles := def.tile_set.tiles
	while not queue.is_empty():
		if def.wfc_max_propagations > 0 and propagations >= def.wfc_max_propagations:
			return propagations
		var cur: int = queue.pop_back()
		propagations += 1
		var cx := cur % grid.width
		var cy := cur / grid.width
		for dir_idx in 4:
			var d: Vector2i = _DIR4[dir_idx]
			var nx := cx + d.x
			var ny := cy + d.y
			if not grid.in_bounds(nx, ny):
				continue
			var ni := ny * grid.width + nx
			if wave[ni] == 0:
				continue
			var allowed := 0
			for a in _wfc_bits(wave[cur]):
				for b in _wfc_bits(wave[ni]):
					if _wfc_compatible(tiles, a, b, dir_idx):
						allowed |= 1 << b
			if allowed == 0:
				wave[ni] = 0  # 矛盾
				queue.append(ni)
				continue
			if (wave[ni] & allowed) != wave[ni]:
				wave[ni] &= allowed
				queue.append(ni)
	return propagations

## socket 匹配：cur 位于邻居的 dir_idx 方向，cur 的 dir 侧 vs 邻居的 opposite 侧
static func _wfc_compatible(tiles: Array, a: int, b: int, dir_idx: int) -> bool:
	var opp := (dir_idx + 2) % 4
	return tiles[a].socket(dir_idx) == tiles[b].socket(opp)

## 加权随机选一个候选瓦片
static func _wfc_weighted_choice(tiles: Array, opts: Array[int], rng: RandomNumberGenerator) -> int:
	var total := 0.0
	for i in opts:
		total += maxf(tiles[i].weight, 0.0)
	if total <= 0.0:
		return opts[rng.randi_range(0, opts.size() - 1)]
	var r := rng.randf() * total
	for i in opts:
		r -= maxf(tiles[i].weight, 0.0)
		if r <= 0.0:
			return i
	return opts[opts.size() - 1]

## 候选集 → 瓦片索引数组
static func _wfc_bits(mask: int) -> Array[int]:
	var out: Array[int] = []
	for i in 30:
		if mask & (1 << i):
			out.append(i)
	return out

static func _wfc_bit_index(mask: int) -> int:
	var i := 0
	while mask > 1:
		mask >>= 1
		i += 1
	return i

const _DIR4: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
