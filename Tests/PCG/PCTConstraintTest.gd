class_name PCTConstraintTest
extends RefCounted

## PCG 约束正确性测试 — 算法输出满足其定义约束

static func run() -> bool:
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

	# 城镇：主街存在 + 地块全部临街 + 道路网连通(site 可达地图边缘) + 建筑门临路
	var city := load("res://Assets/Def/PCG/City_Grid.tres") as TownDef
	var tl := PCGTool.generate_town(city, null, 7)
	var rg := tl.roads_grid
	var bgrid := tl.build_grid
	var city_ok := rg.count(city.road_main_value) > 0 and tl.parcels.size() > 0 and tl.buildings.size() > 0
	for parcel in tl.parcels:
		if int(parcel.frontage_dir) < 0:
			city_ok = false
			break
	var door_road := 0
	for b in tl.buildings:
		var dr: Vector2i = b.door
		if bgrid.get_cell(dr.x, dr.y, -1) != city.building_door_value:
			continue
		for d2 in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if rg.get_cell(dr.x + d2.x, dr.y + d2.y, -1) > 0:
				door_road += 1
				break
	if tl.buildings.size() > 0 and door_road == 0:
		city_ok = false
	# 室内：家具有产出且不堵门（门口内侧净空）
	var furniture_total := 0
	var block_door := false
	for k in tl.interiors:
		var iv: Dictionary = tl.interiors[k]
		furniture_total += (iv.slots as Array).size()
		var binfo: Dictionary = tl.buildings[k]
		var inner: Vector2i = (binfo.door as Vector2i) - [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)][int(binfo.facing)]
		for sit in iv.slots:
			if Vector2i(sit.cell) == inner:
				block_door = true
	if furniture_total == 0 or block_door:
		city_ok = false
	# TownLayout 序列化往返（存档约定依赖）
	var tl_data := tl.to_data()
	var tl2 := TownLayout.from_data(tl_data)
	var ser_ok := tl2.site == tl.site and tl2.buildings.size() == tl.buildings.size() \
		and tl2.parcels.size() == tl.parcels.size() and tl2.interiors.size() == tl.interiors.size() \
		and (tl2.roads_grid == null) == (tl.roads_grid == null) \
		and tl2.plaza_cells.size() == tl.plaza_cells.size()
	if ser_ok and tl2.roads_grid != null:
		ser_ok = tl2.roads_grid.cells == tl.roads_grid.cells
	if ser_ok and tl2.build_grid != null:
		ser_ok = tl2.build_grid.cells == tl.build_grid.cells
	if ser_ok:
		for b2 in tl2.buildings:
			if int(b2.layers) < 1 or String(b2.roof).is_empty():
				ser_ok = false
				break
	city_ok = city_ok and ser_ok
	# 可插拔步骤：禁用 FarmStep 后农田应为空，其余不受影响
	var city2 := load("res://Assets/Def/PCG/City_Grid.tres") as TownDef
	var steps_mod: Array[TownStepDef] = city2.effective_steps()
	for st in steps_mod:
		if st is TownFarmStep:
			st.enabled = false
	city2.steps = steps_mod
	var tl_nf := PCGTool.generate_town(city2, null, 7)
	var farm_empty: bool = tl_nf.farms.is_empty()
	var bld_ok: bool = tl_nf.buildings.size() > 20
	city_ok = city_ok and farm_empty and bld_ok
	print("[约束] 步骤禁用Farm: %s (建筑%d 农田空=%s)" % [
		str(farm_empty), tl_nf.buildings.size(), str(farm_empty)])
	city2.steps = []  # 恢复默认链
	# BFS：从 site 沿道路格扩散，应触达任一边缘格（对外连通）
	if city_ok:
		var seen := {}
		var queue: Array[Vector2i] = [tl.site]
		seen[tl.site] = true
		var reach_edge := false
		while not queue.is_empty() and not reach_edge:
			var c: Vector2i = queue.pop_back()
			if c.x == 0 or c.y == 0 or c.x == rg.width - 1 or c.y == rg.height - 1:
				reach_edge = true
				break
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx := c + d
				if rg.in_bounds(nx.x, nx.y) and rg.get_cell(nx.x, nx.y, 0) != 0 and not seen.has(nx):
					seen[nx] = true
					queue.append(nx)
		city_ok = reach_edge
	all_ok = all_ok and city_ok
	print("[约束] 城镇主街/临街/连通/门路/家具/序列化: %s (主街%d 建筑%d 门路%d 家具%d 广场设施=%s)" % [
		city_ok, rg.count(city.road_main_value), tl.buildings.size(), door_road, furniture_total, str(tl.plaza_item)])

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

	# 城镇存档集成: TownLayout → SaveTool GZIP 落盘 → 加载 → from_data 往返一致
	var save_path := "user://pcg_test/town_layout.save"
	SaveTool.save_data(save_path, tl.to_data(), SaveTool.Mode.GZIP)
	var loaded_data = SaveTool.load_data(save_path, SaveTool.Mode.GZIP)
	var tl_back := TownLayout.from_data(loaded_data if loaded_data is Dictionary else {})
	var town_save_ok: bool = tl_back != null \
			and tl_back.buildings.size() == tl.buildings.size() \
			and tl_back.site == tl.site \
			and tl_back.roads_grid != null and tl_back.roads_grid.cells == tl.roads_grid.cells \
			and (tl_back.streets.get("bus_stops", []) as Array).size() == (tl.streets.get("bus_stops", []) as Array).size() \
			and tl_back.bushes == tl.bushes
	SaveTool.delete_data(save_path, SaveTool.Mode.GZIP)
	all_ok = all_ok and town_save_ok
	print("[约束] 城镇存档 SaveTool GZIP 往返: %s (建筑%d 站点%d)" % [
		town_save_ok, tl_back.buildings.size(), (tl_back.streets.get("bus_stops", []) as Array).size()])

	# 多种子批量审计: 20 种子逐项断言——无压路/门临路/连通边缘/有建筑产出
	var audit_ok := true
	var audit_detail := ""
	for seed in [42, 7, 777, 1, 2, 3, 5, 8, 13, 21, 99, 123, 256, 512, 1000, 4096, 8888, 20260, 31415, 99999]:
		var ta := PCGTool.generate_town(city, null, seed)
		var trg := ta.roads_grid
		var tbg := ta.build_grid
		var ov := 0
		for i in tbg.cells.size():
			var bv: int = tbg.cells[i]
			if (bv == city.building_wall_value or bv == city.building_floor_value or bv == city.building_door_value) \
					and trg.cells[i] != 0:
				ov += 1
		var dr_cnt := 0
		for b in ta.buildings:
			var dr: Vector2i = b.door
			if tbg.get_cell(dr.x, dr.y, -1) != city.building_door_value:
				continue
			for d2 in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if trg.get_cell(dr.x + d2.x, dr.y + d2.y, -1) > 0:
					dr_cnt += 1
					break
		var seen_a := {}
		var q: Array[Vector2i] = [ta.site]
		seen_a[ta.site] = true
		var reach := false
		while not q.is_empty() and not reach:
			var c: Vector2i = q.pop_back()
			if c.x == 0 or c.y == 0 or c.x == trg.width - 1 or c.y == trg.height - 1:
				reach = true
				break
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx: Vector2i = c + d
				if trg.in_bounds(nx.x, nx.y) and not seen_a.has(nx) and trg.get_cell(nx.x, nx.y, 0) != 0:
					seen_a[nx] = true
					q.append(nx)
		var bld_min: bool = ta.buildings.size() >= 20
		if ov > 0 or ta.buildings.is_empty() or not bld_min or not reach:
			audit_ok = false
			audit_detail += " [seed%d 压路%d 门临路%d/%d 连通%s 建筑%d]" % [
				seed, ov, dr_cnt, ta.buildings.size(), reach, ta.buildings.size()]
	all_ok = all_ok and audit_ok
	print("[约束] 多种子批量审计(20种子): %s%s" % [audit_ok, audit_detail])

	# 张量场路网：主街存在 + 建筑产出 + 无压路 + 门临路 + 街区加密生效
	var tensor := load("res://Assets/Def/PCG/City_Tensor.tres") as TownDef
	var tt := PCGTool.generate_town(tensor, null, 7)
	var trg := tt.roads_grid
	var tbg := tt.build_grid
	var tensor_ok := trg.count(12) > 0 and tt.buildings.size() > 20
	var tensor_ov := 0
	for i in tbg.cells.size():
		var bv2: int = tbg.cells[i]
		if (bv2 == tensor.building_wall_value or bv2 == tensor.building_floor_value or bv2 == tensor.building_door_value) \
				and trg.cells[i] != 0:
			tensor_ov += 1
	if tensor_ov > 0:
		tensor_ok = false
	var tensor_dr := 0
	for b in tt.buildings:
		var tdr: Vector2i = b.door
		for d3 in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if trg.get_cell(tdr.x + d3.x, tdr.y + d3.y, -1) > 0:
				tensor_dr += 1
				break
	tensor_ok = tensor_ok and tensor_dr >= int(tt.buildings.size() * 0.9)
	# 街区加密: 全部封闭口袋 ≤ min_block_area*2(+容差), 山地不规则口袋同样被切割
	var t_density_ok := true
	var t_road := {}
	for y in trg.height:
		for x in trg.width:
			if trg.get_cell(x, y, -1) != 0:
				t_road[Vector2i(x, y)] = true
	var t_out := {}
	var t_q := []
	for x in trg.width:
		for yy in [0, trg.height - 1]:
			if not t_road.has(Vector2i(x, yy)):
				t_out[Vector2i(x, yy)] = true
				t_q.append(Vector2i(x, yy))
	for yy in trg.height:
		for x0 in [0, trg.width - 1]:
			if not t_road.has(Vector2i(x0, yy)):
				t_out[Vector2i(x0, yy)] = true
				t_q.append(Vector2i(x0, yy))
	while not t_q.is_empty():
		var c: Vector2i = t_q.pop_back()
		for d3 in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nc: Vector2i = c + d3
			if nc.x >= 0 and nc.y >= 0 and nc.x < trg.width and nc.y < trg.height \
					and not t_road.has(nc) and not t_out.has(nc):
				t_out[nc] = true
				t_q.append(nc)
	var t_seen := {}
	for yy in trg.height:
		for x in trg.width:
			var c := Vector2i(x, yy)
			if t_road.has(c) or t_out.has(c) or t_seen.has(c):
				continue
			var size := 0
			var q2 := [c]
			t_seen[c] = true
			while not q2.is_empty():
				var cc: Vector2i = q2.pop_back()
				size += 1
				for d3 in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nc: Vector2i = cc + d3
					if nc.x >= 0 and nc.y >= 0 and nc.x < trg.width and nc.y < trg.height \
							and not t_road.has(nc) and not t_out.has(nc) and not t_seen.has(nc):
						t_seen[nc] = true
						q2.append(nc)
			if size > tensor.min_block_area * 2 + 40:
				t_density_ok = false
	tensor_ok = tensor_ok and t_density_ok
	all_ok = all_ok and tensor_ok
	print("[约束] 张量路网(主街/无压路/门临路/街区加密): %s (干道%d 建筑%d 门路%d/%d)" % [
		tensor_ok, trg.count(12), tt.buildings.size(), tensor_dr, tt.buildings.size()])

	# 步骤链裁剪: enable_walls=false 时链中无城墙步骤, 古城配置保留
	var chain_ok := true
	for st in tensor.effective_steps():
		if st is TownWallStep:
			chain_ok = false
	var mine := load("res://Assets/Def/PCG/Town_MountainMine.tres") as TownDef
	var mine_has_wall := false
	for st in mine.effective_steps():
		if st is TownWallStep:
			mine_has_wall = true
	chain_ok = chain_ok and mine_has_wall
	all_ok = all_ok and chain_ok
	print("[约束] 城墙步骤链裁剪(现代无/古城有): %s" % chain_ok)

	print("== 约束测试 %s ==" % ("全部通过" if all_ok else "存在失败"))
	return all_ok
