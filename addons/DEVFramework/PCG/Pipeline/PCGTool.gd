@tool
class_name PCGTool
## PCG 运行时入口 — 种子派生 / 3D 体素栅格 / 3D 散布 / 生成管线
##
## ============================ 模块定位 ============================
## 本模块只服务 **3D 模型世界生成**。2D 栅格地图能力（城镇路网、高度图、
## 河流道路、程序化纹理、L-System、模板拼接、内容生成）已整体移除 ——
## 它们产出的是俯视地图数据，与"3D 模型"是两个不同的产物类别，
## 放在同一个模块里只会让"生成 3D 世界"这件事被"生成 2D 地图"淹没。
##
## ============================ 两层结构 ============================
## · **结构层**（本文件：3D 栅格 + 3D WFC）—— 决定"哪里是实心、哪里是空"
## · **造型层**（[SdfField] / [PropGen]）—— 决定"实心的那些长什么形状"
##
## 两层不是二选一，而是互补：WFC 擅长"块状拼接的结构"（房间、模块朝向），
## SDF 擅长"有机造型"（建筑外形、家具）。后者以槽位标签接受前者的调度。
## 层间衔接由 [PropLayoutTool] 负责（贴地 / 朝向 / 避让）。
##
## ============================ 统一中间表示 ============================
## 造型层的统一格式是 [SdfField] —— 一个带材质槽位的连续场。
## 它**一次烘焙、两处投影**：[MeshExtractor] 取等值面得到低多边形网格，
## [VoxelExtractor] 体素化得到体素模型。这是"同一份数据既能出体素
## 又能出 lowpoly"的技术底座，也是换画风不必重算几何的原因
## （画风挂在投影阶段，不沾几何）。
##
## ============================ 三条铁律 ============================
## ① **只设 seed，不设 state** —— 一切生成经 [method make_rng] 派生随机源。
##    直接写 `rng.state` 会让同 seed 的结果依赖调用先后，可复现性整体崩塌。
## ② **存档只存 seed + 增量** —— 见 [method ChunkedWorld3D.save_data]。
##    世界数据永远能从 seed 重放出来，因此分块世界不占存档体积。
## ③ **原生类主线程预热** —— [FrameworkNative] 的 C++ 类首次 instantiate
##    有线程亲和，必须在主线程先碰一下再丢给 worker，否则偶发崩溃。

# ================================================================== 随机

## 创建带种子的随机源。
##
## 这是全模块唯一的随机入口。新增生成功能时**必须**经过它，
## 不要自己 `RandomNumberGenerator.new()` 然后随手设 state —— 那样做
## 的代码换个 seed 就对不上，且无法与其他生成步骤解耦。
static func make_rng(seed: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	return rng

## 从基础种子派生独立子种子。
##
## 管线里每个生成器用不同 slot，保证**加一个生成器不会打乱其他生成器的
## 随机流**。注意 slot 是位置相关的：只往管线中间插入生成器会改变后续
## 全部生成器的结果。想让新增步骤不影响存量，把它的 slot 取一个未使用的
## 固定值（例如 100+）而不是指望追加到末尾。
static func derive_seed(base: int, slot: int) -> int:
	return (base ^ (slot * 0x9E3779B1)) & 0x7FFFFFFF

# ================================================================== 3D 栅格

## 生成 3D 体素栅格。四种算法：
##   [codeblock]
##   NOISE_SURFACE  每 (x,z) 列按噪声高度填充实体 —— 地表 / 丘陵
##   CAVE_NOISE_3D  3D 噪声阈值挖空 —— 连通洞穴网络
##   CAVE_3D        细胞自动机 + 26 邻域平滑 —— 经典 Rogue 洞穴
##   WFC_3D         六面 socket 瓦片约束坍缩 —— 结构化拼接（走 C++）
##   [/codeblock]
##
## [param offset] 由 [ChunkedWorld3D] 注入，使分块世界的噪声**跨块连续**；
## 单块生成时留 0。直接调用时不需要它。
static func generate_grid_3d(def: Grid3DGenDef, rng: RandomNumberGenerator, fixed: Dictionary = {}) -> GeneratedGrid3D:
	var grid := GeneratedGrid3D.create(def.width, def.height, def.depth, def.empty_value)
	match def.type:
		Grid3DGenDef.Type.NOISE_SURFACE:
			_gen3d_surface(grid, def, rng)
		Grid3DGenDef.Type.CAVE_3D:
			_gen3d_cave(grid, def, rng)
		Grid3DGenDef.Type.WFC_3D:
			_gen3d_wfc(grid, def, rng, fixed)
		Grid3DGenDef.Type.CAVE_NOISE_3D:
			_gen3d_noise_cave(grid, def, rng)
	return grid

## 3D 地表：每 (x,z) 列按噪声高度填充实体。
##
## offset 进采样坐标是分块连续的关键 —— 所有 chunk 用**同一种子 + 各自
## offset**，而不是各自独立的种子，否则相邻块的地表高度对不上，缝一眼可见。
static func _gen3d_surface(grid: GeneratedGrid3D, def: Grid3DGenDef, rng: RandomNumberGenerator) -> void:
	var nseed := def.noise_seed if def.noise_seed != 0 else rng.seed
	var noise: FastNoiseLite = def.noise_layer.build_noise(nseed) if def.noise_layer else null
	var base_h := def.base_height * def.height
	for x in grid.width:
		for z in grid.depth:
			var h := base_h
			if noise:
				var n := def.noise_layer.sample(noise, x + def.offset.x, z + def.offset.z)
				h += (n - 0.5) * 2.0 * def.height_amp
			## 夹到 [1, height-1]：下界 1 是因为 y=0 必须留空（体素世界的底面
			## 地板由外部给），上界留一格免得顶面被场边界截断。
			h = clampi(roundi(h), 1, grid.height - 1)
			for y in h:
				grid.set_cell(x, y, z, def.solid_value)

## 3D 噪声洞穴：3D 噪声阈值挖空。
##
## 与 [method _gen3d_cave] 的取舍：细胞自动机出**团块状**洞穴、连通性好；
## 噪声阈值出**丝网状**通道、连通性差但形态自然。两者可叠加。
static func _gen3d_noise_cave(grid: GeneratedGrid3D, def: Grid3DGenDef, rng: RandomNumberGenerator) -> void:
	var nseed := def.noise_seed if def.noise_seed != 0 else rng.seed
	var noise: FastNoiseLite = def.noise_layer.build_noise(nseed) if def.noise_layer else null
	for z in grid.depth:
		for y in grid.height:
			for x in grid.width:
				var v := def.noise_layer.sample_3d(noise, x + def.offset.x, y, z + def.offset.z) if noise else 0.5
				grid.cells[grid._index(x, y, z)] = def.empty_value if v > def.cave_threshold else def.solid_value

## 3D 细胞洞穴：随机填充后做 26 邻域平滑（阈值 ~13），经典 Rogue 扩展法。
##
## 纯 C++ 实现（框架强依赖共享原生库 PCGCave3D，无 GDScript 回退）。
## 平滑是把整块体积丢给原生层的唯一入口，所以 pass 数直接决定耗时。
static func _gen3d_cave(grid: GeneratedGrid3D, def: Grid3DGenDef, rng: RandomNumberGenerator) -> void:
	var native := FrameworkNative.get_native(&"PCGCave3D", [&"generate"])
	if native == null:
		push_error("PCGTool.generate_grid_3d: 原生库 PCGCave3D 不可用! 请确认 Native/dev.gdextension 已加载。")
		return
	var out: PackedInt32Array = native.call(&"generate",
		grid.width, grid.height, grid.depth,
		rng.seed, def.cave_ratio, def.smooth_passes, def.border_solid,
		def.solid_value, def.empty_value)
	if out.size() == grid.cells.size():
		grid.cells = out
	else:
		push_error("PCGTool.generate_grid_3d: PCGCave3D 返回长度异常(%d ≠ %d)。" % [out.size(), grid.cells.size()])

## 3D WFC：六面 socket 瓦片约束坍缩（观测 → 传播 → 回溯 → 重试）。
##
## 瓦片数硬上限 30 —— socket 相容表是 n² 量级，再多就退化到不可用。
##
## [param fixed] 支持四种键形式：[Vector3i] 单格 / [int] 线性索引 /
## [String] "x,y,z" / [AABB] 区域。值均为瓦片索引。
## [param fixed] 与 [member Grid3DGenDef.wfc_fixed_cells] 会**合并**，
## 后者（Def 上的）先写，因此调用方的 fixed 优先级更高。
static func _gen3d_wfc(grid: GeneratedGrid3D, def: Grid3DGenDef, rng: RandomNumberGenerator, fixed: Dictionary = {}) -> void:
	## 注意：`def.tile_set3d.tiles if def.tile_set3d else []` 会在运行期报
	## "Trying to assign an array of type Array to Array[TileDef3D]" ——
	## 三元的两个分支类型不一致（typed array vs 无类型数组），
	## 静态推断给的是后者，运行期给的却是前者。所以老老实实用显式分支。
	var tiles: Array[TileDef3D] = []
	if def.tile_set3d != null:
		tiles = def.tile_set3d.tiles
	var n := tiles.size()
	if n <= 0 or n >= 30:
		grid.fill(def.solid_value)
		return
	## 纯 C++ 实现（框架强依赖共享原生库 PCGWFC3D，无 GDScript 回退）
	var native := FrameworkNative.get_native(&"PCGWFC3D", [&"generate"])
	if native == null:
		push_error("PCGTool.generate_grid_3d: 原生库 PCGWFC3D 不可用! 请确认 Native/dev.gdextension 已加载。")
		grid.fill(def.solid_value)
		return
	## socket 字符串 → 连续 id。
	## 注意：这里必须用显式 for 循环编号而不是 lambda —— lambda 捕获的局部
	## 变量不跨调用持久，用闭包累加 id 会每次都从 0 开始、映射全乱。
	var socket_map := {}
	var next_id := 0
	for t in tiles:
		for dir_i in 6:
			var s := t.socket(dir_i)
			if not socket_map.has(s):
				socket_map[s] = next_id
				next_id += 1
	var sockets := PackedInt32Array()
	var weights := PackedFloat32Array()
	for t in tiles:
		for dir_i in 6:
			sockets.append(int(socket_map[t.socket(dir_i)]))
		weights.append(t.weight)
	## 固定格（硬约束）：坍缩前钉死，坍缩后再校验
	var fixed_idx := PackedInt32Array()
	var fixed_tile := PackedInt32Array()
	var merged := {}
	for key in def.wfc_fixed_cells:
		merged[key] = def.wfc_fixed_cells[key]
	for key in fixed:
		merged[key] = fixed[key]
	for key in merged:
		var tile_idx := int(merged[key])
		if tile_idx < 0 or tile_idx >= n:
			continue
		if key is AABB:
			var bb := key as AABB
			for k in range(int(bb.position.z), int(bb.end.z)):
				for j in range(int(bb.position.y), int(bb.end.y)):
					for i in range(int(bb.position.x), int(bb.end.x)):
						if grid.in_bounds(i, j, k):
							fixed_idx.append(grid._index(i, j, k))
							fixed_tile.append(tile_idx)
			continue
		var idx := _wfc3d_fixed_index(grid, key)
		if idx >= 0:
			fixed_idx.append(idx)
			fixed_tile.append(tile_idx)
	var out: PackedInt32Array = native.call(&"generate",
		grid.width, grid.height, grid.depth, sockets, weights,
		def.wfc_max_backtracks, def.wfc_retries, 0,
		fixed_idx, fixed_tile, rng.seed)
	if out.size() != grid.cells.size():
		push_error("PCGTool.generate_grid_3d: PCGWFC3D 生成失败(重试耗尽)! 请调整 wfc_retries 或瓦片约束。")
		grid.fill(def.solid_value)
		return
	grid.cells = out

## 解析 3D 固定格 key 为线性索引。支持 [Vector3i] / [int] / [String] "x,y,z"。
static func _wfc3d_fixed_index(grid: GeneratedGrid3D, key) -> int:
	if key is Vector3i:
		return grid._index(key.x, key.y, key.z) if grid.in_bounds(key.x, key.y, key.z) else -1
	if key is int:
		return key if key >= 0 and key < grid.cells.size() else -1
	if key is String:
		var parts := String(key).split(",")
		if parts.size() == 3:
			var x := int(parts[0])
			var y := int(parts[1])
			var z := int(parts[2])
			if grid.in_bounds(x, y, z):
				return grid._index(x, y, z)
	return -1

# ================================================================== 3D 异步

## 后台线程生成 3D 栅格（大体积不卡主线程）。
##
## 铁律③：原生类在主线程预热后再进 worker，否则首帧偶发崩溃。
static func generate_grid_3d_async(def: Grid3DGenDef, seed: int) -> GeneratedGrid3D:
	if def.type == Grid3DGenDef.Type.WFC_3D:
		FrameworkNative.get_native(&"PCGWFC3D", [&"generate"])  # 预热(主线程)
	var grid: GeneratedGrid3D = await AsyncTool.thread_call(func() -> GeneratedGrid3D:
		return generate_grid_3d(def, make_rng(seed))
	)
	return grid

## 后台线程生成 3D 栅格 + 实时进度回调（大 3D WFC 不卡帧，UI 可显示进度）。
##
## on_progress: func(p: float)，主线程每帧回调 0..1。
## 进度由 C++ 侧静态量（PCGWFC3D.get_last_progress）记录，主线程轮询它 ——
## worker 线程拿不到主线程的回调时机，所以不能把进度直接算在 worker 里。
static func generate_grid_3d_async_progress(def: Grid3DGenDef, seed: int, on_progress: Callable = func(_p: float): pass) -> GeneratedGrid3D:
	var native: Object = null
	if def.type == Grid3DGenDef.Type.WFC_3D:
		native = FrameworkNative.get_native(&"PCGWFC3D", [&"generate", &"get_last_progress"])  # 预热(主线程)
	var data := {}
	var task_id := WorkerThreadPool.add_task(func():
		data.result = _async_grid3d_work(def, seed)
	)
	while not WorkerThreadPool.is_task_completed(task_id):
		if native != null:
			on_progress.call(native.call(&"get_last_progress"))
		await Engine.get_main_loop().process_frame
	on_progress.call(1.0)
	return data.get("result") as GeneratedGrid3D

## async 3D 工作函数。3D WFC 的进度由 C++ 静态量记录，此处只管调。
static func _async_grid3d_work(def: Grid3DGenDef, seed: int) -> GeneratedGrid3D:
	return generate_grid_3d(def, make_rng(seed))

# ================================================================== 3D 散布

## 在一个 3D 区域里撒点。三种模式：
## [codeblock]
## POISSON_3D    Bridson 3D 泊松盘，最均匀、间距严格 ≥ min_distance
## JITTER_GRID_3D 抖动网格，最快、分布规整但带随机偏移
## RANDOM_3D    均匀随机，最快、可能成堆
## [/codeblock]
static func place_3d(def: PlacementDef3D, rng: RandomNumberGenerator) -> PackedVector3Array:
	match def.mode:
		PlacementDef3D.Mode.POISSON_3D:
			return _place_poisson_3d(def, rng)
		PlacementDef3D.Mode.JITTER_GRID_3D:
			return _place_jitter_grid_3d(def, rng)
		PlacementDef3D.Mode.RANDOM_3D:
			return _place_random_3d(def, rng)
	return PackedVector3Array()

## 3D 泊松圆盘（Bridson 3D）。
##
## 复杂度 O(n)，靠空间哈希 + 每格 5³ 邻域查询避让，
## 比暴力 O(n²) 在大 count 下快一个数量级。
static func _place_poisson_3d(def: PlacementDef3D, rng: RandomNumberGenerator) -> PackedVector3Array:
	var r := maxf(def.min_distance, 0.001)
	## 格边长 = r/√3 是 Bridson 的标准取值：保证每格至多一个候选，
	## 于是邻域只需查 3³ 而不是更大的窗口。
	var cell := r / sqrt(3.0)
	var gw := ceili(def.region_size.x / cell)
	var gh := ceili(def.region_size.y / cell)
	var gd := ceili(def.region_size.z / cell)
	var occupancy := {}
	var result := PackedVector3Array()
	var active := PackedVector3Array()
	var start := Vector3(
		rng.randf_range(0.0, def.region_size.x),
		rng.randf_range(0.0, def.region_size.y),
		rng.randf_range(0.0, def.region_size.z))
	result.append(start)
	active.append(start)
	occupancy[_cell_key(start, cell)] = start
	while not active.is_empty() and result.size() < def.count:
		var idx := rng.randi_range(0, active.size() - 1)
		var center: Vector3 = active[idx]
		var placed := false
		for i in def.max_attempts:
			var dir := Vector3(rng.randf() * 2.0 - 1.0, rng.randf() * 2.0 - 1.0, rng.randf() * 2.0 - 1.0).normalized()
			var cand := center + dir * rng.randf_range(r, r * 2.0)
			if cand.x < 0.0 or cand.y < 0.0 or cand.z < 0.0 or cand.x >= def.region_size.x or cand.y >= def.region_size.y or cand.z >= def.region_size.z:
				continue
			if not _poisson_ok_3d(occupancy, gw, gh, gd, _cell_key(cand, cell), cell, r, cand):
				continue
			result.append(cand)
			active.append(cand)
			occupancy[_cell_key(cand, cell)] = cand
			placed = true
			break
		## 该点周围 max_attempts 次都放不下 → 移出活跃集（标准 Bridson 收敛条件）。
		## 不移出的话会在这里死循环。
		if not placed:
			active.remove_at(idx)
	return result

static func _cell_key(p: Vector3, cell: float) -> Vector3i:
	return Vector3i(int(p.x / cell), int(p.y / cell), int(p.z / cell))

static func _poisson_ok_3d(occupancy: Dictionary, gw: int, gh: int, gd: int, gi: Vector3i, cell: float, r: float, cand: Vector3) -> bool:
	for dz in range(-2, 3):
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var gx := gi.x + dx
				var gy := gi.y + dy
				var gz := gi.z + dz
				if gx < 0 or gy < 0 or gz < 0 or gx >= gw or gy >= gh or gz >= gd:
					continue
				var other: Variant = occupancy.get(Vector3i(gx, gy, gz))
				if other != null and (other as Vector3).distance_to(cand) < r:
					return false
	return true

## 3D 抖动网格：切成 n³ 格、每格中心加随机抖动。n = ∛count。
static func _place_jitter_grid_3d(def: PlacementDef3D, rng: RandomNumberGenerator) -> PackedVector3Array:
	var n := ceili(pow(float(def.count), 1.0 / 3.0))
	var out := PackedVector3Array()
	for i in n:
		for j in n:
			for k in n:
				if out.size() >= def.count:
					break
				var base := Vector3(
					def.region_size.x * (i + 0.5) / n,
					def.region_size.y * (j + 0.5) / n,
					def.region_size.z * (k + 0.5) / n)
				var jx := (rng.randf() - 0.5) * (def.region_size.x / n) * def.jitter
				var jy := (rng.randf() - 0.5) * (def.region_size.y / n) * def.jitter
				var jz := (rng.randf() - 0.5) * (def.region_size.z / n) * def.jitter
				out.append(base + Vector3(jx, jy, jz))
	return out

## 3D 均匀随机。最快，但可能成堆 —— 撒"草丛"可以，撒"树"会挤成一坨。
static func _place_random_3d(def: PlacementDef3D, rng: RandomNumberGenerator) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in def.count:
		out.append(Vector3(
			rng.randf() * def.region_size.x,
			rng.randf() * def.region_size.y,
			rng.randf() * def.region_size.z))
	return out

# ================================================================== 管线

## 执行 [PCGDef] 管线，返回 output 字典（key → 生成结果）。
##
## [codeblock]
## var out := PCGTool.generate(pcg_def)      # 用 def.seed
## var out := PCGTool.generate(pcg_def, 42)  # 覆盖种子
## var grid: GeneratedGrid3D = out["terrain"]
## [/codeblock]
##
## seed 传 0 表示"沿用 Def 上的种子"。之所以把 0 当哨兵而不是默认值，
## 是因为 0 是合法的种子值 —— 用它当"未指定"会让 seed=0 的 Def 静默失效。
##
## 每个生成器拿到 [method derive_seed] 派生的独立 RNG，
## 于是**往管线尾部追加生成器不会改变已有生成器的结果**（slot 是位置索引，
## 追加不影响前面）。但从中间插入会，见 [method derive_seed]。
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
