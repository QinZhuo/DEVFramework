class_name ChunkedWorld3D extends RefCounted
## 3D 分块世界 — 以 (seed, chunk坐标) 确定性懒加载体素 chunk
##
## 地表/噪声洞穴模式用世界坐标偏移采样噪声，相邻 chunk 连续；
## 细胞洞穴每 chunk 独立生成（洞穴本就不需跨块连续）。
## 同一 seed + 同一 (cx,cy,cz) 必然复现同一 chunk。

## chunk 边长（体素格）
var chunk_size := 8
## 世界基础种子
var seed_base := 0
## 每 chunk 的 3D 生成定义（尺寸会被 chunk_size 覆写，offset 设世界坐标）
var grid3d_def: Grid3DGenDef

var _chunks := {}  # Vector3i → GeneratedGrid3D
var _chunk_count := 0
## 玩家修改记录：{"x,y,z" → 值}，存档只存 seed + 改动
var _modified := {}


## 获取 chunk（不存在则按种子确定性生成并缓存）
func get_chunk(cx: int, cy: int, cz: int) -> GeneratedGrid3D:
	var key := Vector3i(cx, cy, cz)
	if not _chunks.has(key):
		var g := _generate_chunk(cx, cy, cz)
		_chunks[key] = g
		_chunk_count += 1
	return _chunks[key]


## 已加载 chunk 列表（Vector3i → GeneratedGrid3D），供渲染/导航构建遍历
func get_loaded_chunks() -> Dictionary:
	return _chunks.duplicate()


func has_chunk(cx: int, cy: int, cz: int) -> bool:
	return _chunks.has(Vector3i(cx, cy, cz))


func get_chunk_count() -> int:
	return _chunk_count


## 手动放入已生成的 chunk（配合异步生成）
func add_chunk(cx: int, cy: int, cz: int, grid: GeneratedGrid3D) -> void:
	var key := Vector3i(cx, cy, cz)
	if _chunks.has(key):
		return
	_chunks[key] = grid
	_chunk_count += 1


## 后台线程生成 chunk（尺寸覆写 + 世界坐标偏移，与 get_chunk 同种子逻辑）
func generate_chunk_async(cx: int, cy: int, cz: int) -> GeneratedGrid3D:
	var d: Grid3DGenDef = grid3d_def.duplicate() as Grid3DGenDef if grid3d_def else null
	if d == null:
		return GeneratedGrid3D.create(chunk_size, chunk_size, chunk_size, 1)
	d.width = chunk_size
	d.height = chunk_size
	d.depth = chunk_size
	if d.type == Grid3DGenDef.Type.NOISE_SURFACE or d.type == Grid3DGenDef.Type.CAVE_NOISE_3D:
		d.offset = Vector3i(cx * chunk_size, 0, cz * chunk_size)
		d.noise_seed = seed_base  # 所有 chunk 同一种子，offset 保证全局连续
	var seed := _chunk_seed(seed_base, cx, cy, cz)
	return await PCGTool.generate_grid_3d_async(d, seed)


## 清空已缓存 chunk（重新取会按同一种子重建）
func clear_chunks() -> void:
	_chunks.clear()
	_chunk_count = 0


## 按世界坐标取体素值（自动懒生成所在 chunk；玩家修改优先）
func get_cell(wx: int, wy: int, wz: int, out_of_bounds := -1) -> int:
	var mkey := "%d,%d,%d" % [wx, wy, wz]
	if _modified.has(mkey):
		return _modified[mkey]
	var cx := floori(wx / float(chunk_size))
	var cy := floori(wy / float(chunk_size))
	var cz := floori(wz / float(chunk_size))
	var lx := wx - cx * chunk_size
	var ly := wy - cy * chunk_size
	var lz := wz - cz * chunk_size
	var g := get_chunk(cx, cy, cz)
	return g.get_cell(lx, ly, lz, out_of_bounds)


## 修改世界体素值（记录进增量存档）
func set_cell(wx: int, wy: int, wz: int, v: int) -> void:
	_modified["%d,%d,%d" % [wx, wy, wz]] = v


func get_modified() -> Dictionary:
	return _modified


func clear_modified() -> void:
	_modified.clear()


## —— 存档（seed + 增量改动） ——

func save_data() -> Dictionary:
	return {
		"seed": seed_base,
		"chunk_size": chunk_size,
		"grid_def": grid3d_def.save_data() if grid3d_def else "",
		"modified": _modified,
	}


func load_data(data: Dictionary) -> void:
	seed_base = int(data.get("seed", seed_base))
	chunk_size = int(data.get("chunk_size", chunk_size))
	var def_path: String = data.get("grid_def", "")
	if not def_path.is_empty():
		var d: Def = Grid3DGenDef.load_data(def_path)
		if d is Grid3DGenDef:
			grid3d_def = d as Grid3DGenDef
	_modified = data.get("modified", {})
	clear_chunks()


func _generate_chunk(cx: int, cy: int, cz: int) -> GeneratedGrid3D:
	var d: Grid3DGenDef = grid3d_def.duplicate() as Grid3DGenDef if grid3d_def else null
	if d == null:
		return GeneratedGrid3D.create(chunk_size, chunk_size, chunk_size, 1)
	d.width = chunk_size
	d.height = chunk_size
	d.depth = chunk_size
	if d.type == Grid3DGenDef.Type.NOISE_SURFACE or d.type == Grid3DGenDef.Type.CAVE_NOISE_3D:
		d.offset = Vector3i(cx * chunk_size, 0, cz * chunk_size)
		d.noise_seed = seed_base  # 所有 chunk 同一种子，offset 保证全局连续
	var seed := _chunk_seed(seed_base, cx, cy, cz)
	return PCGTool.generate_grid_3d(d, PCGTool.make_rng(seed))


## chunk 坐标 → 确定性种子
static func _chunk_seed(base: int, cx: int, cy: int, cz: int) -> int:
	var h := (cx * 73856093) ^ (cy * 19349663) ^ (cz * 83492791)
	return (base ^ h) & 0x7FFFFFFF
