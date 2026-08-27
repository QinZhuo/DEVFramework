class_name PCTDeterminismTest
extends RefCounted

## PCG 确定性测试 — 同 seed 必复现，不同 seed 不同

static func run() -> bool:
	var all_ok := true

	# 2D 网格各算法：同 seed 两次生成必须完全一致
	var defs := {
		"NoiseTerrain": load("res://Assets/Def/PCG/Grid_NoiseTerrain.tres") as GridGenDef,
		"Cave": load("res://Assets/Def/PCG/Grid_Cave.tres") as GridGenDef,
		"Maze": load("res://Assets/Def/PCG/Grid_Maze.tres") as GridGenDef,
		"BSP": load("res://Assets/Def/PCG/Grid_BSPRooms.tres") as GridGenDef,
		"WFC": load("res://Assets/Def/PCG/Grid_WFC.tres") as GridGenDef,
		"Voronoi": load("res://Assets/Def/PCG/Grid_Voronoi.tres") as GridGenDef,
	}
	for name in defs:
		var d: GridGenDef = defs[name]
		var a := PCGTool.generate_grid(d, PCGTool.make_rng(42))
		var b := PCGTool.generate_grid(d, PCGTool.make_rng(42))
		var ok := a.cells == b.cells
		if not ok:
			all_ok = false
		print("[确定性] 2D %s 同seed复现: %s" % [name, ok])

	# WFC 固定格：同 seed + 同固定格复现
	var wfc_def: GridGenDef = defs["WFC"]
	var f := {Vector2i(10, 10): 2, Rect2i(20, 20, 5, 5): 1}
	var fa := PCGTool.generate_grid(wfc_def, PCGTool.make_rng(9), f)
	var fb := PCGTool.generate_grid(wfc_def, PCGTool.make_rng(9), f)
	print("[确定性] WFC 固定格复现: %s" % (fa.cells == fb.cells))

	# 3D 算法：同 seed 复现
	var d3s := {
		"Surface": load("res://Assets/Def/PCG/Grid3D_Surface.tres") as Grid3DGenDef,
		"Cave3D": load("res://Assets/Def/PCG/Grid3D_Cave.tres") as Grid3DGenDef,
		"WFC3D": load("res://Assets/Def/PCG/Grid3D_WFC.tres") as Grid3DGenDef,
		"NoiseCave3D": load("res://Assets/Def/PCG/Grid3D_NoiseCave.tres") as Grid3DGenDef,
	}
	for name in d3s:
		var d: Grid3DGenDef = d3s[name]
		var a := PCGTool.generate_grid_3d(d, PCGTool.make_rng(7))
		var b := PCGTool.generate_grid_3d(d, PCGTool.make_rng(7))
		var ok := a.cells == b.cells
		if not ok:
			all_ok = false
		print("[确定性] 3D %s 同seed复现: %s" % [name, ok])

	# 3D WFC 固定格：同 seed + 同固定格复现
	var wfc3_def: Grid3DGenDef = d3s["WFC3D"]
	var f3 := {Vector3i(2, 2, 2): 0, Vector3i(3, 3, 3): 1, AABB(Vector3(10, 10, 10), Vector3(2, 1, 2)): 0}
	var f3a := PCGTool.generate_grid_3d(wfc3_def, PCGTool.make_rng(5), f3)
	var f3b := PCGTool.generate_grid_3d(wfc3_def, PCGTool.make_rng(5), f3)
	var wfc3_fix_ok := f3a.cells == f3b.cells
	if not wfc3_fix_ok:
		all_ok = false
	print("[确定性] 3D WFC 固定格复现: %s" % wfc3_fix_ok)

	# 城镇：同 seed 复现（道路层/选址/地块全一致），不同 seed 不同
	var city := load("res://Assets/Def/PCG/City_Grid.tres") as TownDef
	var ta := PCGTool.generate_town(city, null, 3)
	var tb := PCGTool.generate_town(city, null, 3)
	var tc := PCGTool.generate_town(city, null, 4)
	var city_ok := ta.roads_grid.cells == tb.roads_grid.cells and ta.site == tb.site \
		and ta.parcels.size() == tb.parcels.size() and ta.roads_grid.cells != tc.roads_grid.cells
	if not city_ok:
		all_ok = false
	print("[确定性] 城镇同 seed 复现/异 seed 不同: %s" % city_ok)

	# 内容进化：同 seed 复现（进化路径确定性）
	var evolve := load("res://Assets/Def/PCG/Evolve_Equipment.tres") as ContentEvolveDef
	var ea := PCGTool.evolve_content(evolve, PCGTool.make_rng(11))
	var eb := PCGTool.evolve_content(evolve, PCGTool.make_rng(11))
	var evolve_ok := ea.size() == eb.size()
	for i in ea.size():
		if ea[i].name != eb[i].name or ea[i].fitness != eb[i].fitness:
			evolve_ok = false
			break
	if not evolve_ok:
		all_ok = false
	print("[确定性] 内容进化同 seed 复现: %s" % evolve_ok)

	# 3D 分块世界：同 seed + 同 chunk 坐标复现
	var world_a := ChunkedWorld3D.new()
	world_a.seed_base = 42
	world_a.grid3d_def = d3s["Surface"]
	world_a.chunk_size = 8
	var world_b := ChunkedWorld3D.new()
	world_b.seed_base = 42
	world_b.grid3d_def = d3s["Surface"]
	world_b.chunk_size = 8
	var wa0: GeneratedGrid3D = world_a.get_chunk(0, 0, 0)
	var wb0: GeneratedGrid3D = world_b.get_chunk(0, 0, 0)
	var world_ok := wa0.cells == wb0.cells
	if not world_ok:
		all_ok = false
	print("[确定性] 3D 分块世界同 seed 复现: %s" % world_ok)

	# 不同 seed 结果应不同（抽样对比）
	var cave: GridGenDef = defs["Cave"]
	var c42 := PCGTool.generate_grid(cave, PCGTool.make_rng(42))
	var c43 := PCGTool.generate_grid(cave, PCGTool.make_rng(43))
	print("[确定性] 不同 seed 不同: %s" % (c42.cells != c43.cells))

	# 管线同 seed 复现
	var pipe := load("res://Assets/Def/PCG/Pipeline_World.tres") as PCGDef
	var oa := PCGTool.generate(pipe, 777)
	var ob := PCGTool.generate(pipe, 777)
	var pipe_ok := true
	for k in oa:
		var va = oa[k]
		var vb = ob[k]
		if va is GeneratedGrid and vb is GeneratedGrid and (va as GeneratedGrid).cells != (vb as GeneratedGrid).cells:
			pipe_ok = false
		elif va is BiomeMap and vb is BiomeMap:
			if (va as BiomeMap).indices != (vb as BiomeMap).indices:
				pipe_ok = false
		elif va is PackedVector2Array and vb is PackedVector2Array and (va as PackedVector2Array) != (vb as PackedVector2Array):
			pipe_ok = false
	print("[确定性] 管线同 seed 复现: %s" % pipe_ok)

	# 张量场路网：同 seed 复现（含街区加密/穿越吸附全部随机路径）
	var tensor := load("res://Assets/Def/PCG/City_Tensor.tres") as TownDef
	var ta2 := PCGTool.generate_town(tensor, null, 77)
	var tb2 := PCGTool.generate_town(tensor, null, 77)
	var tc2 := PCGTool.generate_town(tensor, null, 78)
	var tensor_det_ok := ta2.roads_grid.cells == tb2.roads_grid.cells \
		and ta2.buildings.size() == tb2.buildings.size() \
		and ta2.roads_grid.cells != tc2.roads_grid.cells
	if not tensor_det_ok:
		all_ok = false
	print("[确定性] 张量路网同 seed 复现/异 seed 不同: %s" % tensor_det_ok)

	print("== 确定性测试 %s ==" % ("全部通过" if all_ok else "存在失败"))
	return all_ok
