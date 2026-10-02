class_name PCTBenchmarkTest
extends RefCounted

## PCG 性能基准 — 各 3D 能力耗时统计（GDScript 参考值）
##
## 这不是断言用例（runner 只自动执行 test_ 前缀方法），只打印耗时。
## 需要时手动调用：PCTBenchmarkTest.run()
##
## 耗时只作**相对**参考：换机器、换 GDExtension 构建都会整体平移，
## 不要把它当绝对指标。真正要盯的是"某个算法突然慢一个数量级"。


static func run() -> void:
	print("== PCG 性能基准（3D） ==")

	# —— 3D 栅格各算法（32×24×32 = 24576 格） ——
	var d3s := {
		"Surface": load("res://Assets/Def/PCG/Grid3D_Surface.tres") as Grid3DGenDef,
		"Cave3D": load("res://Assets/Def/PCG/Grid3D_Cave.tres") as Grid3DGenDef,
		"NoiseCave3D": load("res://Assets/Def/PCG/Grid3D_NoiseCave.tres") as Grid3DGenDef,
		"WFC3D(16³)": load("res://Assets/Def/PCG/Grid3D_WFC.tres") as Grid3DGenDef,
	}
	for name in d3s:
		var d: Grid3DGenDef = d3s[name]
		var t := Time.get_ticks_msec()
		var g := PCGTool.generate_grid_3d(d, PCGTool.make_rng(1))
		print("[基准] 3D %-12s %d ms  实体 %d/%d" % [
			name, Time.get_ticks_msec() - t, g.count(d.solid_value), g.cells.size()])

	# —— 3D 散布 ——
	var p := load("res://Assets/Def/PCG/Place_3D_Nature.tres") as PlacementDef3D
	var t := Time.get_ticks_msec()
	var pts := PCGTool.place_3d(p, PCGTool.make_rng(1))
	print("[基准] 3D 泊松散布 %d 点 %d ms" % [pts.size(), Time.get_ticks_msec() - t])

	# —— 分块世界（5³ chunk，同步） ——
	var surface: Grid3DGenDef = d3s["Surface"]
	var world := ChunkedWorld3D.new()
	world.seed_base = 1
	world.grid3d_def = surface
	world.chunk_size = 8
	t = Time.get_ticks_msec()
	for cz in range(-2, 3):
		for cy in range(-2, 3):
			for cx in range(-2, 3):
				world.get_chunk(cx, cy, cz)
	print("[基准] 3D 分块世界 125 chunk %d ms" % [Time.get_ticks_msec() - t])

	# —— 生成管线 ——
	var pipe := load("res://Assets/Def/PCG/Pipeline_World.tres") as PCGDef
	t = Time.get_ticks_msec()
	var out := PCGTool.generate(pipe, 1)
	print("[基准] 生成管线 %d ms（输出 %s）" % [Time.get_ticks_msec() - t, str(out.keys())])

	# —— 场→网格 与 场→体素：同一份SdfField 的两种投影 ——
	# 这一项是本模块的核心主张的耗时对照：双产物不意味着双倍几何计算，
	# 场只烘一次，两种投影各自只做取面/体素化。
	var prop_def := PropGenDef.new()
	prop_def.voxel_size = 0.20
	prop_def.voxel_res = 32
	var gen_script: Script = load("res://Scripts/Gen/ShopGen.gd")
	if gen_script != null:
		var bake_t := Time.get_ticks_msec()
		var build = PropGenTool.bake(gen_script.new(), prop_def, 20261002)
		var bake_ms := Time.get_ticks_msec() - bake_t
		if build != null and not build.is_empty():
			print("[基准] SdfField→网格+体素 %d ms  三角面 %d  实体体素 %d  包围盒 %s" % [
				bake_ms, build.triangle_count(),
				build.voxel.count_solid() if build.has_voxel() else 0,
				str(build.bounds.size)])

	print("== 基准结束 ==")