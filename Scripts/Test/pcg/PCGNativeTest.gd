class_name PCGNativeTest
extends RefCounted

## 原生库可用性与算法行为冒烟
##
## PCG 的 3D 洞穴与 3D WFC **完全跑在 C++ 上，无 GDScript 回退**
## （见 [code]PCGTool._gen3d_cave[/code] / [code]_gen3d_wfc[/code]）。
## 所以原生库没加载时不是"退回慢速实现"，而是整个能力直接失效 ——
## 这里守住那条边界。
##
## 2026-10 的 3D-only 重构后，[code]PCGWFC[/code]（2D WFC）、[code]PCGErode[/code]（2D 侵蚀）、
## [code]PCGLSystem[/code]（L-System）已无 GDScript 调用方，本测试不再覆盖；
## 原生库文件本身保留未动，日后重新接线时再加断言。


static func run() -> bool:
	var checks := {
		&"cave_lib": _cave_lib(),
		&"cave_ok": _cave_ok(),
		&"cave_seeded": _cave_seeded(),
		&"cave_border": _cave_border(),
		&"wfc_lib": _wfc_lib(),
		&"wfc_ok": _wfc_ok(),
		&"wfc_seeded": _wfc_seeded(),
		&"wfc_no_tileset": _wfc_no_tileset(),
	}
	var all_ok := true
	for k in checks:
		print("  [%s] %s" % ["OK" if checks[k] else "!!", k])
		if not checks[k]:
			all_ok = false
	return all_ok


# ================================================================== 3D 细胞洞穴

static func _cave_def() -> Grid3DGenDef:
	return load("res://Assets/Def/PCG/Grid3D_Cave.tres") as Grid3DGenDef


static func _cave_lib() -> bool:
	return FrameworkNative.get_native(&"PCGCave3D", [&"generate"]) != null


## 生成一次并检查规模落在合理区间。
## 只查"不崩"太弱：原生层返回长度不对时 [code]PCGTool[/code] 会push_error
## 但仍然交回一个空栅格，不检查的话症状是"世界一片空"。
static func _cave_ok() -> bool:
	var def := _cave_def()
	if def == null:
		return false
	var g := PCGTool.generate_grid_3d(def, PCGTool.make_rng(11))
	if g == null:
		return false
	if g.cells.size() != g.width * g.height * g.depth:
		return false
	var ratio := float(g.count(def.solid_value)) / float(g.cells.size())
	## border_solid=true 会把外壳铺满，实心率天然偏高，区间取 0.3~0.95
	return ratio > 0.3 and ratio < 0.95


## 同 seed 复现、异 seed 不同 —— 两条一起断言，只写前者会漏掉"随机流没接上"。
static func _cave_seeded() -> bool:
	var def := _cave_def()
	if def == null:
		return false
	var a := PCGTool.generate_grid_3d(def, PCGTool.make_rng(5))
	var b := PCGTool.generate_grid_3d(def, PCGTool.make_rng(5))
	var c := PCGTool.generate_grid_3d(def, PCGTool.make_rng(6))
	return a.cells == b.cells and a.cells != c.cells


## border_solid=true 时最外一圈必须全是实体，否则洞穴会从世界边界漏光。
static func _cave_border() -> bool:
	var def := _cave_def()
	if def == null:
		return false
	var g := PCGTool.generate_grid_3d(def, PCGTool.make_rng(11))
	for x in g.width:
		if g.get_cell(x, 0, 0) != def.solid_value or g.get_cell(x, g.height - 1, g.depth - 1) != def.solid_value:
			return false
	for z in g.depth:
		if g.get_cell(0, 0, z) != def.solid_value or g.get_cell(g.width - 1, 0, z) != def.solid_value:
			return false
	return true


# ================================================================== 3D WFC

static func _wfc_def() -> Grid3DGenDef:
	return load("res://Assets/Def/PCG/Grid3D_WFC.tres") as Grid3DGenDef


static func _wfc_lib() -> bool:
	return FrameworkNative.get_native(&"PCGWFC3D", [&"generate", &"get_last_progress"]) != null


## WFC 成功时栅格里必然出现两种瓦片值（Checker 集有 A/B 两片）；
## 失败时 [code]PCGTool[/code] 会把栅格整体填成 solid_value，
## 于是"只有一种值"就是失败的信号。
static func _wfc_ok() -> bool:
	var def := _wfc_def()
	if def == null:
		return false
	var g := PCGTool.generate_grid_3d(def, PCGTool.make_rng(7))
	if g == null or g.cells.is_empty():
		return false
	var kinds := {}
	for v in g.cells:
		kinds[v] = true
	return kinds.size() >= 2


## 塌缩算法最容易出的错是随机流没接上：每次跑出来一模一样，
## 而"能跑通、结果合法"完全看不出来。
## （[code]PackedInt32Array[/code] 没有 [method hash]，用手动滚动哈希做指纹。）
static func _wfc_seeded() -> bool:
	var def := _wfc_def()
	if def == null:
		return false
	var seen := {}
	for s in [1, 2, 3, 4, 5, 6, 7, 8]:
		seen[_fingerprint(PCGTool.generate_grid_3d(def, PCGTool.make_rng(s)).cells)] = true
	return seen.size() >= 4


static func _fingerprint(cells: PackedInt32Array) -> int:
	var h := 17
	for v in cells:
		h = (h * 31 + v) & 0x7fffffff
	return h


## 瓦片集为空/越界时必须直接填满实体并返回，不能去调原生层 ——
## 原生层拿到 0 个瓦片会崩，而这里的失败方式是"世界全是实心"，属于可接受的降级。
##
## ★ 必须 [method Resource.duplicate]：`.tres` 在运行时是**共享单例**，
## 直接改`def.tile_set3d` 会污染同一次会话里所有后续用例 ——
## 症状是本用例自己通过，而后面依赖该瓦片集的 WFC 断言莫名全挂。
static func _wfc_no_tileset() -> bool:
	var base := _wfc_def()
	if base == null:
		return false
	var def := base.duplicate() as Grid3DGenDef
	def.tile_set3d = null
	var g := PCGTool.generate_grid_3d(def, PCGTool.make_rng(3))
	return g.count(def.solid_value) == g.cells.size()
