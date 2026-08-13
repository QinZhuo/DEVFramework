class_name NavBridgeTool
## 项目侧导航桥接工具（非框架 PCG 模块）
##
## 职责：把 PCG 生成的纯数据栅格（GeneratedGrid / GeneratedGrid3D）转成 Godot 原生寻路对象
## （NavigationPolygon / NavigationMesh / AStarGrid2D），供 NavigationAgent 等使用。
##
## 设计说明：PCG 模块只负责"生成核心数据"，不实现"消费数据"的导航网格/mesh 生成逻辑。
## 本项目 3D 导航网格直接复用 **Godot 引擎自带烘焙**（NavigationServer3D.bake_from_source_geometry_data）：
## 把体素地表转成源几何三角面，交给引擎按 cell_size / agent_radius / 斜坡规则烘焙，不手写多边形算法。
## 2D 的 NavigationPolygon 无烘焙概念，手写顶点多边形是引擎标准做法。

## 一步配置 2D 导航区域：构建 NavigationPolygon 挂到 region（含 use_edge_connections / agent_radius）
## offset 为世界坐标偏移（如地图原点），NavigationRegion2D 保持在原点，poly 顶点即世界坐标
static func setup_navigation_2d(region: NavigationRegion2D, grid: GeneratedGrid, empty_value := 0, tile_size := 1.0, cell_inset := 0.0, offset := Vector2.ZERO, agent_radius := 0.0, use_edge_connections := true) -> NavigationPolygon:
	region.position = Vector2.ZERO
	region.use_edge_connections = use_edge_connections
	var poly := build_navigation_2d(grid, empty_value, tile_size, cell_inset, offset)
	poly.agent_radius = agent_radius
	region.navigation_polygon = poly
	return poly


## 把栅格可走区域转成 NavigationPolygon，挂到 NavigationRegion2D.navigation_polygon 即可用 Godot 自带寻路
## empty_value: 可走格的值（栅格数据仅记录整数值）；tile_size: 每格世界尺寸；cell_inset: 每格内缩量（避免贴墙碰撞）
## offset: 世界坐标偏移（如地图原点），NavigationRegion2D 保持原点时顶点即世界坐标；agent_radius: agent 半径内缩（需 bake 后生效，纯数据构建下仅作记录）
static func build_navigation_2d(grid: GeneratedGrid, empty_value := 0, tile_size := 1.0, cell_inset := 0.0, offset := Vector2.ZERO, agent_radius := 0.0) -> NavigationPolygon:
	var poly := NavigationPolygon.new()
	if agent_radius > 0.0:
		poly.agent_radius = agent_radius
	var verts := PackedVector2Array()
	var vmap := {}
	var w := grid.width
	var h := grid.height
	for y in h:
		for x in w:
			if grid.get_cell(x, y) != empty_value:
				continue
			var pts := [
				Vector2((x + cell_inset) * tile_size, (y + cell_inset) * tile_size) + offset,
				Vector2((x + 1.0 - cell_inset) * tile_size, (y + cell_inset) * tile_size) + offset,
				Vector2((x + 1.0 - cell_inset) * tile_size, (y + 1.0 - cell_inset) * tile_size) + offset,
				Vector2((x + cell_inset) * tile_size, (y + 1.0 - cell_inset) * tile_size) + offset,
			]
			var keys := [
				y * (w + 1) + x,
				y * (w + 1) + x + 1,
				(y + 1) * (w + 1) + x + 1,
				(y + 1) * (w + 1) + x,
			]
			var poly_idx := PackedInt32Array()
			for i in 4:
				if not vmap.has(keys[i]):
					vmap[keys[i]] = verts.size()
					verts.append(pts[i])
				poly_idx.append(vmap[keys[i]])
			poly.add_polygon(poly_idx)
	poly.set_vertices(verts)
	return poly


## 把栅格转成 Godot 自带 AStarGrid2D（格子寻路，逐格路径无抖动，回合制/格游首选）
## cell_size: 每格世界尺寸（格坐标即世界坐标，用 Vector2(tile_size, tile_size) 对齐地图）
static func grid_to_astar_grid(grid: GeneratedGrid, empty_value := 0, cell_size := Vector2.ONE) -> AStarGrid2D:
	var astar := AStarGrid2D.new()
	astar.region = Rect2i(0, 0, grid.width, grid.height)
	astar.cell_size = cell_size
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	astar.update()
	for y in grid.height:
		for x in grid.width:
			if grid.get_cell(x, y) != empty_value:
				astar.set_point_solid(Vector2i(x, y), true)
	astar.update()
	return astar


# —— 3D：复用 Godot 引擎导航烘焙（NavigationServer3D.bake_from_source_geometry_data） ——

## 一步配置 3D 导航区域：体素地表 → 源几何 → 引擎烘焙成 NavigationMesh 挂到 region
## offset 为世界坐标偏移，NavigationRegion3D 保持在原点，mesh 顶点即世界坐标
## agent_radius: agent 半径（烘焙时自动收缩可走面边缘）；cell_size: 烘焙栅格精度（默认 1.0）
## bake_async: 是否后台线程烘焙（大世界建议 true，避免卡主线程）
static func setup_navigation_3d(region: NavigationRegion3D, grid: GeneratedGrid3D, solid_value := 1, offset := Vector3.ZERO, agent_radius := 0.4, cell_size := 0.25, use_edge_connections := true, bake_async := false) -> NavigationMesh:
	region.position = Vector3.ZERO
	region.use_edge_connections = use_edge_connections
	var mesh := bake_navigation_3d(grid, solid_value, offset, agent_radius, cell_size, bake_async)
	region.navigation_mesh = mesh
	return mesh


## 体素栅格 → 源几何 → 引擎烘焙 NavigationMesh（替代手写多边形算法）
## 把每个实体格的顶面（上方为空）作为可走地表三角面加入源几何，其余连通/斜坡/边缘收缩全交给引擎。
## solid_value: 实体格值；offset: 世界坐标偏移；agent_radius: agent 半径（烘焙自动收缩）；cell_size: 烘焙精度
static func bake_navigation_3d(grid: GeneratedGrid3D, solid_value := 1, offset := Vector3.ZERO, agent_radius := 0.4, cell_size := 0.25, bake_async := false) -> NavigationMesh:
	var nav_mesh := NavigationMesh.new()
	nav_mesh.cell_size = cell_size
	nav_mesh.cell_height = cell_size
	nav_mesh.agent_radius = maxf(agent_radius, cell_size)
	nav_mesh.agent_height = 1.5
	nav_mesh.agent_max_climb = 1.0
	nav_mesh.agent_max_slope = 60.0
	nav_mesh.filter_low_hanging_obstacles = true
	nav_mesh.filter_ledge_spans = true
	nav_mesh.filter_walkable_low_height_spans = true
	# 收集地表顶面三角面（每个实体格顶面 = 2 个三角形，顺时针绕序）
	var faces := PackedVector3Array()
	var w := grid.width
	var h := grid.height
	var d := grid.depth
	for z in d:
		for x in w:
			for y in h:
				if grid.get_cell(x, y, z) != solid_value:
					continue
				if grid.get_cell(x, y + 1, z, -1) == solid_value:
					continue
				var top_y := y + 1
				var p0 := Vector3(x, top_y, z) + offset
				var p1 := Vector3(x + 1, top_y, z) + offset
				var p2 := Vector3(x + 1, top_y, z + 1) + offset
				var p3 := Vector3(x, top_y, z + 1) + offset
				# 两个三角形（俯视逆时针 → 从上方看是逆时针，法线朝上）
				faces.append(p0)
				faces.append(p1)
				faces.append(p2)
				faces.append(p0)
				faces.append(p2)
				faces.append(p3)
	var geometry := NavigationMeshSourceGeometryData3D.new()
	geometry.add_faces(faces, Transform3D.IDENTITY)
	if bake_async:
		var source_geometry := geometry
		NavigationServer3D.bake_from_source_geometry_data_async(nav_mesh, source_geometry)
	else:
		NavigationServer3D.bake_from_source_geometry_data(nav_mesh, geometry)
	return nav_mesh


## 分块世界 → 引擎烘焙 NavigationMesh：合并已加载 chunk 的地表源几何后整体烘焙
## chunk_size: 每 chunk 边长（格）；chunk 世界偏移 = chunk坐标 × chunk_size（cell_size 缩放后对齐）
## agent_radius: agent 半径；cell_size: 烘焙精度；bake_async: 是否后台线程烘焙
static func bake_navigation_3d_chunks(chunks: Dictionary, chunk_size: int, solid_value := 1, agent_radius := 0.4, cell_size := 0.25, bake_async := false) -> NavigationMesh:
	var nav_mesh := NavigationMesh.new()
	nav_mesh.cell_size = cell_size
	nav_mesh.cell_height = cell_size
	nav_mesh.agent_radius = maxf(agent_radius, cell_size)
	nav_mesh.agent_height = 1.5
	nav_mesh.agent_max_climb = 1.0
	nav_mesh.agent_max_slope = 60.0
	nav_mesh.filter_low_hanging_obstacles = true
	nav_mesh.filter_ledge_spans = true
	nav_mesh.filter_walkable_low_height_spans = true
	var faces := PackedVector3Array()
	for ckey: Vector3i in chunks.keys():
		var grid: GeneratedGrid3D = chunks[ckey]
		var base := Vector3i(ckey.x * chunk_size, 0, ckey.z * chunk_size)
		var w := grid.width
		var h := grid.height
		var d := grid.depth
		for z in d:
			for x in w:
				for y in h:
					if grid.get_cell(x, y, z) != solid_value:
						continue
					if grid.get_cell(x, y + 1, z, -1) == solid_value:
						continue
					var top_y := y + 1
					var wx := base.x + x
					var wz := base.z + z
					var p0 := Vector3(wx, top_y, wz)
					var p1 := Vector3(wx + 1, top_y, wz)
					var p2 := Vector3(wx + 1, top_y, wz + 1)
					var p3 := Vector3(wx, top_y, wz + 1)
					faces.append(p0)
					faces.append(p1)
					faces.append(p2)
					faces.append(p0)
					faces.append(p2)
					faces.append(p3)
	var geometry := NavigationMeshSourceGeometryData3D.new()
	geometry.add_faces(faces, Transform3D.IDENTITY)
	if bake_async:
		NavigationServer3D.bake_from_source_geometry_data_async(nav_mesh, geometry)
	else:
		NavigationServer3D.bake_from_source_geometry_data(nav_mesh, geometry)
	return nav_mesh
