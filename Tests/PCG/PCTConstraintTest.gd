class_name PCTConstraintTest
extends RefCounted

## PCG 约束正确性测试 — 算法输出满足其定义约束

static func run() -> void:
	var all_ok := true

	# 迷宫：完美迷宫通道应全连通（空连通域 == 1）
	var maze := load("res://Assets/Def/PCG/Grid_Maze.tres") as GridGenDef
	var mg := PCGTool.generate_grid(maze, PCGTool.make_rng(20260811))
	var maze_comps := mg.components(0).size()
	var maze_ok := maze_comps == 1
	all_ok = all_ok and maze_ok
	print("[约束] 迷宫通道连通域==1: %s (实际 %d)" % [maze_ok, maze_comps])

	# BSP：房间走廊应全连通（空连通域 == 1）
	var bsp := load("res://Assets/Def/PCG/Grid_BSPRooms.tres") as GridGenDef
	var bg := PCGTool.generate_grid(bsp, PCGTool.make_rng(20260811))
	var bsp_comps := bg.components(0).size()
	var bsp_ok := bsp_comps == 1
	all_ok = all_ok and bsp_ok
	print("[约束] BSP 房间连通域==1: %s (实际 %d)" % [bsp_ok, bsp_comps])

	# 模板拼接：所有模板房间连通
	var stitch := load("res://Assets/Def/PCG/Stitch_Dungeon.tres") as TemplateStitchDef
	var sg := PCGTool.generate_template_stitch(stitch, PCGTool.make_rng(20260811))
	var stitch_comps := sg.components(0).size()
	var stitch_ok := stitch_comps == 1
	all_ok = all_ok and stitch_ok
	print("[约束] 模板拼接连通域==1: %s (实际 %d)" % [stitch_ok, stitch_comps])

	# 3D 洞穴：空腔连通（空连通域 == 1）
	var c3 := load("res://Assets/Def/PCG/Grid3D_Cave.tres") as Grid3DGenDef
	var cg := PCGTool.generate_grid_3d(c3, PCGTool.make_rng(20260811))
	var cave3_comps := cg.components(0).size()
	var cave3_ok := cave3_comps == 1
	all_ok = all_ok and cave3_ok
	print("[约束] 3D 洞穴空腔连通域==1: %s (实际 %d)" % [cave3_ok, cave3_comps])

	# 3D WFC：棋盘瓦片垂直交替（A/B 无同色相邻）
	var w3 := load("res://Assets/Def/PCG/Grid3D_WFC.tres") as Grid3DGenDef
	var wg := PCGTool.generate_grid_3d(w3, PCGTool.make_rng(42))
	var violations := 0
	for z in wg.depth:
		for y in range(wg.height - 1):
			for x in wg.width:
				if wg.get_cell(x, y, z) == wg.get_cell(x, y + 1, z):
					violations += 1
	var wfc3_ok := violations == 0
	all_ok = all_ok and wfc3_ok
	print("[约束] 3D WFC 垂直交替无违规: %s (违规 %d)" % [wfc3_ok, violations])

	# 泊松散布：任意两点最小间距满足 min_distance
	var p := load("res://Assets/Def/PCG/Placement_Poisson.tres") as PlacementDef
	var pts := PCGTool.place(p, PCGTool.make_rng(99))
	var poisson_ok := true
	for i in pts.size():
		for j in range(i + 1, pts.size()):
			if pts[i].distance_to(pts[j]) < p.min_distance - 0.01:
				poisson_ok = false
				break
	all_ok = all_ok and poisson_ok
	print("[约束] 泊松最小间距: %s (%d 点)" % [poisson_ok, pts.size()])

	# 序列化往返：GeneratedGrid / GeneratedGrid3D
	var cave := load("res://Assets/Def/PCG/Grid_Cave.tres") as GridGenDef
	var cg2 := PCGTool.generate_grid(cave, PCGTool.make_rng(5))
	var round2 := GeneratedGrid.from_data(cg2.to_data())
	var ser2_ok := round2.cells == cg2.cells and round2.width == cg2.width
	all_ok = all_ok and ser2_ok
	var s3 := load("res://Assets/Def/PCG/Grid3D_Surface.tres") as Grid3DGenDef
	var vg := PCGTool.generate_grid_3d(s3, PCGTool.make_rng(5))
	var round3 := GeneratedGrid3D.from_data(vg.to_data())
	var ser3_ok := round3.cells == vg.cells and round3.depth == vg.depth
	all_ok = all_ok and ser3_ok
	print("[约束] 序列化往返 2D/3D: %s / %s" % [ser2_ok, ser3_ok])

	# 增量存档：seed 复现 + 改动恢复
	var world := ChunkedWorld.new()
	world.seed_base = 20260811
	world.grid_def = cave
	world.chunk_size = 16
	world.get_chunk(0, 0)
	world.set_cell(3, 4, 9)
	var data := world.save_data()
	var world2 := ChunkedWorld.new()
	world2.load_data(data)
	var save_ok := world2.get_cell(3, 4) == 9 and world2.get_cell(5, 5) == world.get_cell(5, 5)
	all_ok = all_ok and save_ok
	print("[约束] 增量存档 seed+改动: %s" % save_ok)

	# 3D WFC 固定格：单格固定被严格遵守（棋盘瓦片集区域全固定无解，故只测单格）
	var wfc3 := load("res://Assets/Def/PCG/Grid3D_WFC.tres") as Grid3DGenDef
	var fixed3 := {Vector3i(2, 2, 2): 0, Vector3i(3, 3, 3): 1, "7,7,7": 0}
	var fg := PCGTool.generate_grid_3d(wfc3, PCGTool.make_rng(5), fixed3)
	var f3_ok := fg.get_cell(2, 2, 2) == 0 and fg.get_cell(3, 3, 3) == 1 and fg.get_cell(7, 7, 7) == 0
	all_ok = all_ok and f3_ok
	print("[约束] 3D WFC 固定格遵守: %s" % f3_ok)

	# 城市：道路网格 + 建筑/公园存在
	var city := load("res://Assets/Def/PCG/City_Grid.tres") as CityDef
	var city_g := PCGTool.generate_city(city, PCGTool.make_rng(7))
	var city_ok := city_g.count(city.building_value) > 0 and city_g.count(city.road_value) > 0 and city_g.count(city.park_value) > 0
	# 道路网格应规整：第 0 行 / 第 0 列是道路（road_width 起）
	for x in city.road_width:
		if city_g.get_cell(x, 0, -1) != city.road_value:
			city_ok = false
	all_ok = all_ok and city_ok
	print("[约束] 城市道路/建筑/公园: %s (建%d 路%d 园%d)" % [
		city_ok, city_g.count(city.building_value), city_g.count(city.road_value), city_g.count(city.park_value)])

	# 3D 噪声洞穴跨 chunk 连续（世界坐标 offset）
	var nc3 := load("res://Assets/Def/PCG/Grid3D_NoiseCave.tres") as Grid3DGenDef
	var nw := ChunkedWorld3D.new()
	nw.seed_base = 42
	nw.grid3d_def = nc3
	nw.chunk_size = 8
	var nc0: GeneratedGrid3D = nw.get_chunk(0, 0, 0)
	var nc1: GeneratedGrid3D = nw.get_chunk(1, 0, 0)
	var continuous_ok := true
	for z in 8:
		for y in 8:
			if nc0.get_cell(7, y, z) != nc1.get_cell(0, y, z):
				continuous_ok = false
	all_ok = all_ok and continuous_ok
	print("[约束] 3D 噪声洞穴跨 chunk 连续: %s" % continuous_ok)

	# 内容进化：收敛到高适应度（应接近最优 雷霆+雷霆=18）
	var evolve := load("res://Assets/Def/PCG/Evolve_Equipment.tres") as ContentEvolveDef
	var evo := PCGTool.evolve_content(evolve, PCGTool.make_rng(1))
	var evo_top := 0.0
	if not evo.is_empty():
		evo_top = (evo[0] as Dictionary).get("fitness", 0.0)
	var evo_ok := not evo.is_empty() and evo_top >= 18.0
	all_ok = all_ok and evo_ok
	print("[约束] 内容进化收敛 top=%.1f: %s" % [evo_top, evo_ok])

	# 洞穴连通性：CONNECT_ALL 后任意种子空连通域都应为 1
	var cave_def2 := load("res://Assets/Def/PCG/Grid_Cave.tres") as GridGenDef
	var cave_conn_ok := true
	for seed in [1, 42, 777, 20260811, 12345]:
		var cg3 := PCGTool.generate_grid(cave_def2, PCGTool.make_rng(seed))
		if cg3.components(0).size() != 1:
			cave_conn_ok = false
	all_ok = all_ok and cave_conn_ok
	print("[约束] 细胞洞穴任意 seed 空连通域==1: %s" % cave_conn_ok)

	print("== 约束测试 %s ==" % ("全部通过" if all_ok else "存在失败"))
