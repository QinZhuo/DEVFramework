class_name PCTBenchmarkTest
extends RefCounted

## PCG 性能基准 — 各算法耗时统计（GDScript 参考值）

static func run() -> void:
	print("== PCG 性能基准 ==")

	# 2D 网格各算法（96x96 = 9216 格）
	var defs := {
		"NoiseTerrain": load("res://Assets/Def/PCG/Grid_NoiseTerrain.tres") as GridGenDef,
		"Cave": load("res://Assets/Def/PCG/Grid_Cave.tres") as GridGenDef,
		"Maze": load("res://Assets/Def/PCG/Grid_Maze.tres") as GridGenDef,
		"BSP": load("res://Assets/Def/PCG/Grid_BSPRooms.tres") as GridGenDef,
		"WFC(64)": load("res://Assets/Def/PCG/Grid_WFC.tres") as GridGenDef,
		"Voronoi": load("res://Assets/Def/PCG/Grid_Voronoi.tres") as GridGenDef,
	}
	for name in defs:
		var d: GridGenDef = defs[name]
		var t := Time.get_ticks_msec()
		PCGTool.generate_grid(d, PCGTool.make_rng(1))
		print("[基准] 2D %-12s %d ms" % [name, Time.get_ticks_msec() - t])

	# 散布
	var p := load("res://Assets/Def/PCG/Placement_Poisson.tres") as PlacementDef
	var t := Time.get_ticks_msec()
	PCGTool.place(p, PCGTool.make_rng(1))
	print("[基准] Poisson 散布 %d ms" % [Time.get_ticks_msec() - t])

	# 群系
	var bm := load("res://Assets/Def/PCG/Biome_World.tres") as BiomeMapDef
	t = Time.get_ticks_msec()
	PCGTool.generate_biome(bm, PCGTool.make_rng(1))
	print("[基准] 生物群系 %d ms" % [Time.get_ticks_msec() - t])

	# 3D 算法（32x24x32 = 24576 格）
	var d3s := {
		"Surface": load("res://Assets/Def/PCG/Grid3D_Surface.tres") as Grid3DGenDef,
		"Cave3D": load("res://Assets/Def/PCG/Grid3D_Cave.tres") as Grid3DGenDef,
		"WFC3D(16³)": load("res://Assets/Def/PCG/Grid3D_WFC.tres") as Grid3DGenDef,
	}
	for name in d3s:
		var d: Grid3DGenDef = d3s[name]
		t = Time.get_ticks_msec()
		PCGTool.generate_grid_3d(d, PCGTool.make_rng(1))
		print("[基准] 3D %-12s %d ms" % [name, Time.get_ticks_msec() - t])

	# 分块世界（7x7 chunk）
	var cave := load("res://Assets/Def/PCG/Grid_Cave.tres") as GridGenDef
	var world := ChunkedWorld.new()
	world.seed_base = 1
	world.grid_def = cave
	world.chunk_size = 16
	t = Time.get_ticks_msec()
	for cy in range(-3, 4):
		for cx in range(-3, 4):
			world.get_chunk(cx, cy)
	print("[基准] 分块世界 49 chunk %d ms" % [Time.get_ticks_msec() - t])

	# 管线
	var pipe := load("res://Assets/Def/PCG/Pipeline_World.tres") as PCGDef
	t = Time.get_ticks_msec()
	PCGTool.generate(pipe, 1)
	print("[基准] 综合管线 %d ms" % [Time.get_ticks_msec() - t])

	print("== 基准结束 ==")
