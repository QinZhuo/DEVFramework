class_name NavBridgeTool
## 项目侧导航桥接工具（非框架 PCG 模块）
##
## 职责：把 PCG 生成的纯数据体素栅格（[GeneratedGrid3D]）转成 Godot 原生寻路对象
## （[NavigationMesh]），供 [NavigationAgent3D] 等使用。
##
## == 设计取舍 ==
## 本工具**不手写多边形算法**：把体素地表转成源几何三角面（每格顶面两个三角形），
## 交给引擎自带的 [method NavigationServer3D.bake_from_source_geometry_data]按
## cell_size / agent_radius / 斜坡规则烘焙。理由是 Godot 的烘焙器已处理连通性、
## 低悬障碍、陡坎与边缘收缩，手写一份只会得到一个更差的近似。
##
## 2D 的 [NavigationPolygon] 无烘焙概念、只能手搓顶点多边形，因此本工具只做 3D；
## 2D 栅格地图生成已于 2026-10 从 PCG 移除，对应能力一并去掉。

## 一步配置 3D 导航区域：体素地表 → 源几何 → 引擎烘焙成 NavigationMesh 挂到 region
## offset 为世界坐标偏移，NavigationRegion3D 保持在原点，mesh 顶点即世界坐标
## agent_radius: agent 半径（烘焙时自动收缩可走面边缘）；cell_size: 烘焙栅格精度（默认 0.25）
## bake_async: 是否后台线程烘焙（大世界建议 true，避免卡主线程）
static func setup_navigation_3d(region: NavigationRegion3D, grid: GeneratedGrid3D, solid_value := 1, offset := Vector3.ZERO, agent_radius := 0.4, cell_size := 0.25, use_edge_connections := true, bake_async := false) -> NavigationMesh:
	region.position = Vector3.ZERO
	region.use_edge_connections = use_edge_connections
	var mesh := bake_navigation_3d(grid, solid_value, offset, agent_radius, cell_size, bake_async)
	region.navigation_mesh = mesh
	return mesh


## 体素栅格 → 源几何 → 引擎烘焙 NavigationMesh（替代手写多边形算法）
## solid_value: 实体格值；offset: 世界坐标偏移；agent_radius: agent 半径（烘焙自动收缩）；cell_size: 烘焙精度
static func bake_navigation_3d(grid: GeneratedGrid3D, solid_value := 1, offset := Vector3.ZERO, agent_radius := 0.4, cell_size := 0.25, bake_async := false) -> NavigationMesh:
	var faces := _terrain_faces(grid, solid_value, offset)
	return _bake_nav(faces, agent_radius, cell_size, bake_async)


## 分块世界 → 引擎烘焙 NavigationMesh：合并已加载 chunk 的地表源几何后整体烘焙
## chunk_size: 每 chunk 边长（格）；chunk 世界偏移 = chunk 坐标 × chunk_size
static func bake_navigation_3d_chunks(chunks: Dictionary, chunk_size: int, solid_value := 1, agent_radius := 0.4, cell_size := 0.25, bake_async := false) -> NavigationMesh:
	var faces := PackedVector3Array()
	for ckey: Vector3i in chunks.keys():
		var grid: GeneratedGrid3D = chunks[ckey]
		var base := Vector3(ckey.x * chunk_size, 0, ckey.z * chunk_size)
		faces.append_array(_terrain_faces(grid, solid_value, base))
	return _bake_nav(faces, agent_radius, cell_size, bake_async)


# ================================================================== 内部

static func _bake_nav(faces: PackedVector3Array, agent_radius: float, cell_size: float, bake_async: bool) -> NavigationMesh:
	var nav_mesh := _make_nav_mesh(agent_radius, cell_size)
	var geometry := NavigationMeshSourceGeometryData3D.new()
	geometry.add_faces(faces, Transform3D.IDENTITY)
	if bake_async:
		NavigationServer3D.bake_from_source_geometry_data_async(nav_mesh, geometry)
	else:
		NavigationServer3D.bake_from_source_geometry_data(nav_mesh, geometry)
	return nav_mesh


## 烘焙参数：三个 filter 是让引擎自动处理台阶/断崖/低矮缝隙的开关，全开。
static func _make_nav_mesh(agent_radius: float, cell_size: float) -> NavigationMesh:
	var nav_mesh := NavigationMesh.new()
	nav_mesh.cell_size = cell_size
	nav_mesh.cell_height = cell_size
	## agent_radius 必须不小于 cell_size，否则边缘收缩会把整块可走面吃掉
	nav_mesh.agent_radius = maxf(agent_radius, cell_size)
	nav_mesh.agent_height = 1.5
	nav_mesh.agent_max_climb = 1.0
	nav_mesh.agent_max_slope = 60.0
	nav_mesh.filter_low_hanging_obstacles = true
	nav_mesh.filter_ledge_spans = true
	nav_mesh.filter_walkable_low_height_spans = true
	return nav_mesh


## 收集地表顶面三角面：实体格且**正上方为空**才算可走面。
## 少了"上方为空"这一条，埋在地下的格子也会被当成路面，agent 直接穿地。
static func _terrain_faces(grid: GeneratedGrid3D, solid_value: int, offset: Vector3) -> PackedVector3Array:
	var faces := PackedVector3Array()
	for z in grid.depth:
		for y in grid.height:
			for x in grid.width:
				if grid.get_cell(x, y, z) != solid_value:
					continue
				if grid.get_cell(x, y + 1, z, -1) == solid_value:
					continue
				var t := y + 1
				var p0 := Vector3(x, t, z) + offset
				var p1 := Vector3(x + 1, t, z) + offset
				var p2 := Vector3(x + 1, t, z + 1) + offset
				var p3 := Vector3(x, t, z + 1) + offset
				# 俯视逆时针 → 法线朝上
				faces.append(p0)
				faces.append(p1)
				faces.append(p2)
				faces.append(p0)
				faces.append(p2)
				faces.append(p3)
	return faces
