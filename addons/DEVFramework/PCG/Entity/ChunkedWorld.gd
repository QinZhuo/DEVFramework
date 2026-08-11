class_name ChunkedWorld extends RefCounted
## 分块世界 — 以 (base_seed, chunk坐标) 确定性懒加载每个 chunk
##
## 同一 seed_base + 同一 (cx, cy) 必然生成同一 chunk，天然支持无限世界 / 存档复现。
## 用法:
##   var world := ChunkedWorld.new()
##   world.seed_base = 20260811
##   world.grid_def = grid_gen_def          # 任意 GridGenDef，chunk 尺寸自动按 chunk_size 覆写
##   var g := world.get_chunk(3, -2)        # 懒生成
##   var v := world.get_cell(50, 30)        # 直接按世界坐标取值

## chunk 边长（像素格）
var chunk_size := 16
## 世界基础种子
var seed_base := 0
## 每 chunk 的生成定义（width/height 会被 chunk_size 覆写，不污染原 Def）
var grid_def: GridGenDef

var _chunks := {}  # Vector2i → GeneratedGrid
var _chunk_count := 0

## 获取 chunk（不存在则按种子确定性生成并缓存）
func get_chunk(cx: int, cy: int) -> GeneratedGrid:
	var key := Vector2i(cx, cy)
	if not _chunks.has(key):
		var g := _generate_chunk(cx, cy)
		_chunks[key] = g
		_chunk_count += 1
	return _chunks[key]

## 手动放入已生成的 chunk（配合异步后台生成使用）
func add_chunk(cx: int, cy: int, grid: GeneratedGrid) -> void:
	var key := Vector2i(cx, cy)
	if _chunks.has(key):
		return
	_chunks[key] = grid
	_chunk_count += 1

## 后台线程生成 chunk（按 chunk_size 覆写定义尺寸，与 _generate_chunk 同种子逻辑）
func generate_chunk_async(cx: int, cy: int) -> GeneratedGrid:
	var d: GridGenDef = grid_def.duplicate() as GridGenDef if grid_def else null
	if d == null:
		return GeneratedGrid.create(chunk_size, chunk_size, 1)
	d.width = chunk_size
	d.height = chunk_size
	var seed := _chunk_seed(seed_base, cx, cy)
	return await PCGTool.generate_grid_async(d, seed)

## 是否已生成过该 chunk
func has_chunk(cx: int, cy: int) -> bool:
	return _chunks.has(Vector2i(cx, cy))

## 已生成的 chunk 数量
func get_chunk_count() -> int:
	return _chunk_count

## 清空已缓存 chunk（内存释放，重新 get 会按同一种子重建）
func clear_chunks() -> void:
	_chunks.clear()
	_chunk_count = 0

## 按世界坐标取格值（越界返回 out_of_bounds；自动懒生成所在 chunk）
func get_cell(world_x: int, world_y: int, out_of_bounds := -1) -> int:
	var cx := floori(world_x / float(chunk_size))
	var cy := floori(world_y / float(chunk_size))
	var lx := world_x - cx * chunk_size
	var ly := world_y - cy * chunk_size
	var g := get_chunk(cx, cy)
	return g.get_cell(lx, ly, out_of_bounds)

func _generate_chunk(cx: int, cy: int) -> GeneratedGrid:
	var d: GridGenDef = grid_def.duplicate() as GridGenDef if grid_def else null
	if d == null:
		return GeneratedGrid.create(chunk_size, chunk_size, 1)
	d.width = chunk_size
	d.height = chunk_size
	var seed := _chunk_seed(seed_base, cx, cy)
	return PCGTool.generate_grid(d, PCGTool.make_rng(seed))

## chunk 坐标 → 确定性种子（大质数混合，不同坐标不同种子）
static func _chunk_seed(base: int, cx: int, cy: int) -> int:
	var h := (cx * 73856093) ^ (cy * 19349663)
	return (base ^ h) & 0x7FFFFFFF
