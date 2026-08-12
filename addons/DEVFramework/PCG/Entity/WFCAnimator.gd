class_name WFCAnimator extends RefCounted
## WFC 生成过程动画器 — 分步执行"观测 → 传播"，随时渲染当前波函数状态
##
## 用于可视化 WFC 的生成过程：未坍缩格显示候选瓦片平均色（熵越高越杂），
## 已确定格显示瓦片色，矛盾格显示红色。
## 用法:
##   var anim := WFCAnimator.new()
##   anim.setup(def, rng, fixed)
##   while not anim.step():            # 逐帧推进，每帧调若干次
##       tex.texture = anim.render_image()

var def: GridGenDef
var rng: RandomNumberGenerator
var fixed: Dictionary = {}
var wave := PackedInt32Array()
var width := 0
var height := 0
var tiles: Array = []
var done := false
var failed := false
var step_count := 0

var _queue: Array[int] = []
var _propagations := 0
var _history: Array = []
var _backtracks := 0


## 初始化波函数（应用固定格并先传播一轮）
func setup(p_def: GridGenDef, p_rng: RandomNumberGenerator, p_fixed: Dictionary = {}) -> void:
	def = p_def
	rng = p_rng
	fixed = p_fixed
	width = def.width
	height = def.height
	tiles = def.tile_set.tiles if def.tile_set else []
	done = false
	failed = false
	step_count = 0
	_propagations = 0
	_backtracks = 0
	_history.clear()
	_queue.clear()
	var n := tiles.size()
	wave.resize(width * height)
	wave.fill((1 << n) - 1 if n > 0 and n < 30 else 0)
	# 应用固定格（运行时 fixed 优先于资源内 wfc_fixed_cells）
	var merged := {}
	for key in def.wfc_fixed_cells:
		merged[key] = def.wfc_fixed_cells[key]
	for key in fixed:
		merged[key] = fixed[key]
	for key in merged:
		var tile_idx := int(merged[key])
		if tile_idx < 0 or tile_idx >= n:
			continue
		# 区域约束：Rect2i 键 = 区域内所有格固定为该瓦片
		if key is Rect2i:
			var r := key as Rect2i
			for ry in range(maxi(0, r.position.y), mini(height, r.end.y)):
				for rx in range(maxi(0, r.position.x), mini(width, r.end.x)):
					var ri := ry * width + rx
					wave[ri] = 1 << tile_idx
					_queue.append(ri)
			continue
		var idx := _fixed_index(key)
		if idx >= 0:
			wave[idx] = 1 << tile_idx
			_queue.append(idx)
	_propagate()


## 推进一步（一次观测+传播），完成时返回 true
func step() -> bool:
	if done or failed:
		return true
	var cell := _pick_lowest_entropy()
	if cell == -1:
		done = true
		failed = _has_contradiction()
		return true
	var opts := _bits(wave[cell])
	if opts.is_empty():
		# 矛盾 → 回溯到上一次观测（与 PCGTool 相同策略）
		if def.wfc_max_backtracks > 0 and _backtracks < def.wfc_max_backtracks and not _history.is_empty():
			_backtracks += 1
			var h: Dictionary = _history.pop_back()
			wave = h.wave_copy.duplicate()
			wave[h.cell] &= ~h.bad
			_queue.append(h.cell)
			_propagate()
			step_count += 1
			return false
		failed = true
		done = true
		return true
	var chosen := _weighted_choice(opts)
	if def.wfc_max_backtracks > 0:
		_history.append({"cell": cell, "wave_copy": wave.duplicate(), "bad": 1 << chosen})
	wave[cell] = 1 << chosen
	_queue.append(cell)
	_propagate()
	step_count += 1
	return false


## 渲染当前波函数状态
func render_image() -> Image:
	var img := Image.create(width, height, false, Image.FORMAT_RGB8)
	for i in wave.size():
		var m := wave[i]
		var c := Color(0.1, 0.1, 0.1)
		if m == 0:
			c = Color(0.75, 0.15, 0.15)  # 矛盾
		elif (m & (m - 1)) == 0:
			var ti := _bit_index(m)
			c = tiles[ti].color if ti >= 0 and ti < tiles.size() else Color.WHITE
		else:
			c = _average_color(m)
		img.set_pixel(i % width, i / width, c)
	return img


## —— 内部 ——

func _pick_lowest_entropy() -> int:
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


func _propagate() -> void:
	while not _queue.is_empty():
		if def.wfc_max_propagations > 0 and _propagations >= def.wfc_max_propagations:
			break
		var cur: int = _queue.pop_back()
		_propagations += 1
		var cx := cur % width
		var cy := cur / width
		for dir_idx in 4:
			var d := _DIR4[dir_idx]
			var nx := cx + d.x
			var ny := cy + d.y
			if nx < 0 or nx >= width or ny < 0 or ny >= height:
				continue
			var ni := ny * width + nx
			if wave[ni] == 0:
				continue
			var allowed := 0
			for a in _bits(wave[cur]):
				for b in _bits(wave[ni]):
					if _compatible(a, b, dir_idx):
						allowed |= 1 << b
			if allowed == 0:
				wave[ni] = 0
				_queue.append(ni)
				continue
			if (wave[ni] & allowed) != wave[ni]:
				wave[ni] &= allowed
				_queue.append(ni)


func _compatible(a: int, b: int, dir_idx: int) -> bool:
	var opp := (dir_idx + 2) % 4
	return tiles[a].socket(dir_idx) == tiles[b].socket(opp)


func _weighted_choice(opts: Array[int]) -> int:
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


func _bits(mask: int) -> Array[int]:
	var out: Array[int] = []
	for i in 30:
		if mask & (1 << i):
			out.append(i)
	return out


func _bit_index(mask: int) -> int:
	var i := 0
	while mask > 1:
		mask >>= 1
		i += 1
	return i


func _average_color(mask: int) -> Color:
	var acc := Color(0, 0, 0)
	var cnt := 0
	for i in tiles.size():
		if mask & (1 << i):
			acc += tiles[i].color
			cnt += 1
	return acc / maxi(cnt, 1)


func _fixed_index(key) -> int:
	if key is Vector2i:
		return key.y * width + key.x if key.x >= 0 and key.x < width and key.y >= 0 and key.y < height else -1
	if key is int:
		return key if key >= 0 and key < width * height else -1
	if key is String:
		var parts := String(key).split(",")
		if parts.size() == 2:
			var x := int(parts[0])
			var y := int(parts[1])
			if x >= 0 and x < width and y >= 0 and y < height:
				return y * width + x
	return -1


func _has_contradiction() -> bool:
	for v in wave:
		if v == 0:
			return true
	return false


const _DIR4: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
