extends Node3D
## PCG 3D 演示 · 体素地形 / 洞穴
##
## 生成 GeneratedGrid3D 并用 MultiMesh 体素化显示，鼠标左键拖拽旋转查看。
## 算法与 2D 相同思想（噪声高度图 / 细胞自动机），验证 PCG 的 3D 基石。

@export var grid3d_defs: Array[Resource] = []

@onready var camera: Camera3D = %Camera3D
@onready var world: Node3D = %World
@onready var algo_option: OptionButton = %AlgoOption
@onready var seed_spin: SpinBox = %SeedSpin
@onready var log_box: RichTextLabel = %LogBox
@onready var nav_region: NavigationRegion3D = %NavRegion3D

var _yaw := 0.7
var _pitch := 0.25


func _ready() -> void:
	for i in grid3d_defs.size():
		var d: Resource = grid3d_defs[i]
		var label := d.resource_path.get_file().get_basename() if d and not d.resource_path.is_empty() else ("资源%d" % i)
		algo_option.add_item(label, i)
	algo_option.item_selected.connect(func(_i: int) -> void: _generate())
	seed_spin.value_changed.connect(func(_v: float) -> void: _generate())
	_generate()
	_update_camera()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_yaw -= event.relative.x * 0.008
		_pitch = clampf(_pitch - event.relative.y * 0.008, -1.45, 1.45)
		_update_camera()


func _update_camera() -> void:
	var size := maxf(1.0, _current_size())
	var dist := size * 1.3
	var pos := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * dist
	camera.position = pos
	camera.look_at(Vector3.ZERO, Vector3.UP)


func _current_size() -> float:
	var res := _selected_res()
	if res is CityDef:
		return maxf(float(res.width), float(res.height))
	return maxf(maxf(res.width if res else 32, res.height if res else 32), res.depth if res else 32)


func _selected_res() -> Resource:
	if algo_option.selected < 0 or algo_option.selected >= grid3d_defs.size():
		return null
	return grid3d_defs[algo_option.selected]


func _on_regen_pressed() -> void:
	_generate()


func _generate() -> void:
	var res := _selected_res()
	if res == null:
		_log("请配置 grid3d_defs")
		return
	if res is CityDef:
		_gen_town_3d(res as CityDef)
		return
	var def := res as Grid3DGenDef
	var fixed := {}
	var fixed_note := ""
	if def.type == Grid3DGenDef.Type.WFC_3D and def.tile_set3d:
		# 演示 3D WFC 固定格：随机固定少量格（手绘部分），WFC 自动补全其余
		var frng := PCGTool.make_rng(int(seed_spin.value) + 1)
		var n_tiles := def.tile_set3d.tiles.size()
		for i in 6:
			var p := Vector3i(
				frng.randi_range(3, def.width - 4),
				frng.randi_range(3, def.height - 4),
				frng.randi_range(3, def.depth - 4))
			fixed[p] = frng.randi_range(0, maxi(0, n_tiles - 1))
		fixed_note = "固定格 %d" % fixed.size()
	var grid := PCGTool.generate_grid_3d(def, PCGTool.make_rng(int(seed_spin.value)), fixed)
	_render(grid, def)
	var solid := grid.count(def.solid_value)
	var empty := grid.cells.size() - solid
	var comps := grid.components(def.empty_value)
	var tail := ""
	if def.type == Grid3DGenDef.Type.WFC_3D:
		tail = "   %s（手绘格自动补全）" % fixed_note
	_log("3D %s:  %dx%dx%d\n实体 %d ／ 空 %d%s\n鼠标左键拖拽旋转" % [
		def.name, grid.width, grid.height, grid.depth, solid, empty, tail,
	])
	_build_navigation(grid, def)


func _render(grid: GeneratedGrid3D, def: Grid3DGenDef) -> void:
	for child in world.get_children():
		child.queue_free()
	if def.type == Grid3DGenDef.Type.WFC_3D:
		# 3D WFC：按瓦片值分组渲染（每组一种颜色），所有瓦片都渲染（含值 0）
		var groups := {}  # value → Array[Vector3]
		for i in grid.cells.size():
			var v := grid.cells[i]
			var x := i % grid.width
			var y := (i / grid.width) % grid.height
			var z := i / (grid.width * grid.height)
			var pos := Vector3(x - grid.width / 2.0, y - grid.height / 2.0, z - grid.depth / 2.0)
			if not groups.has(v):
				groups[v] = []
			(groups[v] as Array).append(pos)
		for v in groups:
			var color := Color(0.7, 0.7, 0.7)
			if def.tile_set3d and v >= 0 and v < def.tile_set3d.tiles.size():
				color = def.tile_set3d.tiles[v].color
			_add_mesh(PackedVector3Array(groups[v]), color, false)
		_log_tail("WFC 瓦片 %d 种，渲染格 %d" % [groups.size(), grid.cells.size()])
		return
	# 地表 / 洞穴
	var pts := PackedVector3Array()
	if def.type == Grid3DGenDef.Type.CAVE_3D:
		for i in grid.cells.size():
			if grid.cells[i] != def.empty_value:
				continue
			var x := i % grid.width
			var y := (i / grid.width) % grid.height
			var z := i / (grid.width * grid.height)
			pts.append(Vector3(x - grid.width / 2.0, y - grid.height / 2.0, z - grid.depth / 2.0))
		_add_mesh(pts, Color(0.3, 0.7, 0.85, 0.55), true)
	else:
		for i in grid.cells.size():
			if grid.cells[i] != def.solid_value:
				continue
			var x := i % grid.width
			var y := (i / grid.width) % grid.height
			var z := i / (grid.width * grid.height)
			if y == 0:
				continue
			var exposed := false
			for d in _DIR6:
				if grid.get_cell(x + d.x, y + d.y, z + d.z, def.empty_value) == def.empty_value:
					exposed = true
					break
			if exposed:
				pts.append(Vector3(x - grid.width / 2.0, y - grid.height / 2.0, z - grid.depth / 2.0))
		_add_mesh(pts, Color(0.6, 0.65, 0.72), false)
	_log_tail("渲染格 %d / 实体 %d 空 %d" % [pts.size(), grid.count(def.solid_value), grid.count(def.empty_value)])


func _add_mesh(pts: PackedVector3Array, color: Color, transparent: bool) -> void:
	_add_mesh_sized(pts, color, Vector3.ONE, transparent)


func _add_mesh_sized(pts: PackedVector3Array, color: Color, size: Vector3, transparent := false, emission := Color(0, 0, 0)) -> void:
	if pts.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	if transparent:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if emission.a > 0.0:
		mat.emission_enabled = true
		mat.emission = emission
	mesh.material = mat
	mm.mesh = mesh
	mm.instance_count = pts.size()
	for i in pts.size():
		mm.set_instance_transform(i, Transform3D(Basis(), pts[i]))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	world.add_child(mmi)


func _log_tail(tail: String) -> void:
	if log_box:
		log_box.text += "\n" + tail


## 桥接 PCG 栅格 → Godot 自带 3D 导航（NavBridgeTool 生成源几何 → 引擎烘焙 NavigationMesh）
func _build_navigation(grid: GeneratedGrid3D, def: Grid3DGenDef) -> void:
	# 地图以中心为原点，世界坐标偏移 = -(width/2, height/2, depth/2)
	var origin := Vector3(-grid.width / 2.0, -grid.height / 2.0, -grid.depth / 2.0)
	NavBridgeTool.setup_navigation_3d(nav_region, grid, def.solid_value, origin, 0.5, 0.25)
	# 导航地图需同步后才能查询路径，延迟到下一物理帧实测
	_test_navigation(grid)


func _test_navigation(grid: GeneratedGrid3D) -> void:
	# 烘焙与 region 注册到 NavigationServer 需要时间，延迟后重取 map 再实测寻路
	await get_tree().create_timer(0.6).timeout
	if not is_inside_tree():
		return
	var map := nav_region.get_navigation_map()
	var mesh := nav_region.navigation_mesh
	if mesh.get_vertices().size() < 3 or mesh.get_polygon_count() < 1:
		_log_tail("导航网格为空（无可走面）")
		return
	# 用 closest_point 取两个确定在导航面内的点测路径
	var a := NavigationServer3D.map_get_closest_point(map, Vector3(-grid.width / 4.0, 5, -grid.depth / 4.0))
	var b := NavigationServer3D.map_get_closest_point(map, Vector3(grid.width / 4.0, 5, grid.depth / 4.0))
	var path := NavigationServer3D.map_get_path(map, a, b, true)
	_log_tail("导航网格（引擎烘焙）：顶点 %d ／ 多边形 %d ／ 路径测试 %s" % [
		mesh.get_vertices().size(), mesh.get_polygon_count(), "OK(%d 点)" % path.size() if not path.is_empty() else "空",
	])


const _DIR6: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]


## —— 城镇 3D 消费示例：TownLayout → 体块化建筑 + 引擎导航寻路验证 ——

func _gen_town_3d(def: CityDef) -> void:
	var t0 := Time.get_ticks_usec()
	var layout := PCGTool.generate_town(def, null, int(seed_spin.value))
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_render_town(layout, def)
	_build_town_navigation(layout, def)
	_update_camera()
	var poi := 0
	for b in layout.buildings:
		if String(b.type) != "住宅":
			poi += 1
	_log("城镇 3D: %s\n建筑 %d (设施 %d)｜地块 %d｜环路 %d 格\n生成 %.0fms ／ 鼠标左键拖拽旋转" % [
		def.name, layout.buildings.size(), poi, layout.parcels.size(),
		layout.roads_grid.count(def.road_ring_value), ms,
	])


## TownLayout 三层栅格 → MultiMesh 体块（道路/广场/墙体/地板/门/家具/围栏 分组着色）
func _render_town(layout: TownLayout, def: CityDef) -> void:
	for child in world.get_children():
		child.queue_free()
	var grid: GeneratedGrid = layout.roads_grid
	var bg: GeneratedGrid = layout.build_grid
	var w := grid.width
	var d := grid.height
	var to_world := func(x: int, z: int) -> Vector3:
		return Vector3(x - w / 2.0 + 0.5, 0, z - d / 2.0 + 0.5)
	# 草地基板（城镇模式配置天空盒+环境光，避免暗色 albedo 在纯平行光下发黑）
	var env := get_node_or_null("Env") as WorldEnvironment
	if env:
		var sky := Sky.new()
		var smat := ProceduralSkyMaterial.new()
		smat.sky_top_color = Color(0.32, 0.52, 0.85)
		smat.sky_horizon_color = Color(0.72, 0.8, 0.9)
		smat.ground_bottom_color = Color(0.3, 0.33, 0.36)
		smat.ground_horizon_color = Color(0.66, 0.73, 0.82)
		sky.sky_material = smat
		env.environment.background_mode = Environment.BG_SKY
		env.environment.sky = sky
		env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.environment.ambient_light_energy = 1.3
	var sun := get_node_or_null("Sun") as DirectionalLight3D
	if sun:
		sun.light_energy = 1.5
	var ground := MeshInstance3D.new()
	var gm := BoxMesh.new()
	gm.size = Vector3(w, 0.2, d)
	gm.material = StandardMaterial3D.new()
	gm.material.albedo_color = Color(0.36, 0.52, 0.3)
	ground.mesh = gm
	ground.position = Vector3(0, -0.1, 0)
	world.add_child(ground)
	# 道路层（按值分组，不同高度微差避免 z-fighting）
	var road_style := {
		def.road_main_value: [Color(0.9, 0.78, 0.4), 0.18],
		def.road_sec_value: [Color(0.5, 0.52, 0.56), 0.15],
		def.road_alley_value: [Color(0.36, 0.38, 0.42), 0.13],
		def.road_ring_value: [Color(0.72, 0.6, 0.35), 0.15],
		def.bridge_value: [Color(0.45, 0.68, 0.85), 0.2],
	}
	for v in road_style:
		var pts := PackedVector3Array()
		for z in d:
			for x in w:
				if grid.get_cell(x, z, -1) == int(v):
					pts.append(to_world.call(x, z))
		_add_mesh_sized(pts, road_style[v][0], Vector3(1, float(road_style[v][1]), 1))
	# 广场
	var plaza_pts := PackedVector3Array()
	for idx in layout.plaza_cells:
		plaza_pts.append(to_world.call(int(idx) % w, int(idx) / w))
	_add_mesh_sized(plaza_pts, Color(0.6, 0.58, 0.52), Vector3(1, 0.14, 1))
	# 建筑：墙体按 (类型, 层数) 分组（高度=层数语义），地板薄板
	var wall_groups := {}  # "fac_2"/"house_1" → pts
	var fac_cells := {}
	var house_cells := {}
	var layers_of := {}  # 墙格 → 该建筑层数
	for b in layout.buildings:
		var target := fac_cells if String(b.type) != "住宅" else house_cells
		for yy in range(b.rect.position.y, b.rect.end.y):
			for xx in range(b.rect.position.x, b.rect.end.x):
				target[Vector2i(xx, yy)] = true
				layers_of[Vector2i(xx, yy)] = int(b.layers)
	var floors := PackedVector3Array()
	for z in d:
		for x in w:
			var c := Vector2i(x, z)
			var v := bg.get_cell(x, z, -1)
			if v == def.building_wall_value:
				var gkey := ("fac_" if fac_cells.has(c) else "house_") + str(int(layers_of.get(c, 1)))
				if not wall_groups.has(gkey):
					wall_groups[gkey] = PackedVector3Array()
				wall_groups[gkey].append(to_world.call(x, z))
			elif v == def.building_floor_value:
				floors.append(to_world.call(x, z))
	for gkey in wall_groups:
		var is_fac_g: bool = String(gkey).begins_with("fac")
		var ln: int = int(String(gkey).get_slice("_", 1))
		_add_mesh_sized(wall_groups[gkey], Color(0.55, 0.57, 0.65) if is_fac_g else Color(0.36, 0.23, 0.14), Vector3(1, ln * 1.5 + 0.9, 1))
	_add_mesh_sized(floors, Color(0.62, 0.48, 0.3), Vector3(1, 0.1, 1))
	# 屋顶（屋檐板+屋脊）、发光窗、定向门板
	var win_along_x := PackedVector3Array()
	var win_along_z := PackedVector3Array()
	var door_along_x := PackedVector3Array()
	var door_along_z := PackedVector3Array()
	for b in layout.buildings:
		var is_fac := String(b.type) != "住宅"
		var wall_set: Dictionary = fac_cells if is_fac else house_cells
		var rect: Rect2i = b.rect
		var blayers: int = int(b.layers)
		var top_h := blayers * 1.5 + 0.9
		var center: Vector3 = to_world.call(rect.get_center().x, rect.get_center().y)
		var eave_y := top_h + 0.12
		var ridge_y := eave_y + 0.36
		var eave_size := Vector3(rect.size.x + 0.6, 0.24, rect.size.y + 0.6)
		var ridge_size := Vector3(maxf(1.0, rect.size.x * 0.55), 0.5, maxf(1.0, rect.size.y * 0.55))
		# 屋顶按语义类型：gable 双坡(檐+脊)；flat 平顶只留檐口女儿墙
		if String(b.roof) == "flat":
			_add_box(Vector3(center.x, eave_y, center.z),
					Vector3(rect.size.x + 0.2, 0.35, rect.size.y + 0.2),
					Color(0.4, 0.44, 0.52) if is_fac else Color(0.45, 0.32, 0.24))
		else:
			_add_box(Vector3(center.x, eave_y, center.z), eave_size,
					Color(0.42, 0.46, 0.58) if is_fac else Color(0.5, 0.22, 0.14))
			_add_box(Vector3(center.x, ridge_y, center.z), ridge_size,
					Color(0.48, 0.52, 0.62) if is_fac else Color(0.56, 0.28, 0.17))
		# 发光窗：每层一排、棋盘间隔，贴暴露面外侧（按暴露轴分薄板方向）
		for row in maxi(1, blayers - (0 if is_fac else 0)):
			var wy := 1.15 + row * 1.5
			for yy in range(rect.position.y, rect.end.y):
				for xx in range(rect.position.x, rect.end.x):
					if not wall_set.has(Vector2i(xx, yy)) or (xx + yy + row) % 2 == 1:
						continue
					for dd: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
						if not wall_set.has(Vector2i(xx + dd.x, yy + dd.y)):
							var wp: Vector3 = to_world.call(xx, yy) + Vector3(dd.x * 0.53, wy, dd.y * 0.53)
							if dd.x != 0:
								win_along_x.append(wp)
							else:
								win_along_z.append(wp)
							break
		# 定向门板（薄轴与墙面垂直）
		var dr: Vector2i = b.door
		var dp: Vector3 = to_world.call(dr.x, dr.y) + Vector3(0, 0.05, 0)
		if int(b.facing) == 1 or int(b.facing) == 3:
			door_along_x.append(dp)
		else:
			door_along_z.append(dp)
	var roof_win := Color(1.0, 0.88, 0.5)
	_add_mesh_sized(win_along_x, roof_win, Vector3(0.16, 0.75, 0.7), false, roof_win)
	_add_mesh_sized(win_along_z, roof_win, Vector3(0.7, 0.75, 0.16), false, roof_win)
	var door_col := Color(1.0, 0.62, 0.15)
	_add_mesh_sized(door_along_x, door_col, Vector3(0.3, 2.5, 0.9))
	_add_mesh_sized(door_along_z, door_col, Vector3(0.9, 2.5, 0.3))
	# 家具 / 装饰 / 围栏
	var furn := PackedVector3Array()
	var props := PackedVector3Array()
	var yard := PackedVector3Array()
	for k in layout.interiors:
		var iv: Dictionary = layout.interiors[k]
		for sit in iv.slots:
			var sc: Vector2i = sit.cell
			furn.append(to_world.call(sc.x, sc.y))
		for pit in iv.props:
			var pc: Vector2i = pit.cell
			props.append(to_world.call(pc.x, pc.y))
		for yc in iv.get("yard", []):
			yard.append(to_world.call(yc.x, yc.y))
	_add_mesh_sized(furn, Color(0.72, 0.5, 0.9), Vector3(0.55, 0.55, 0.55))
	_add_mesh_sized(props, Color(0.42, 0.36, 0.28), Vector3(0.45, 0.45, 0.45))
	_add_mesh_sized(yard, Color(0.28, 0.19, 0.11), Vector3(0.95, 0.6, 0.3))
	# 选址标记柱
	var site_mark := PackedVector3Array([to_world.call(layout.site.x, layout.site.y)])
	_add_mesh_sized(site_mark, Color(1.0, 0.25, 0.1), Vector3(1.2, 6.0, 1.2))


## 城镇导航：可行走面 = 道路/广场/室内地板，墙体为三层实体障碍 → 引擎烘焙后实测跨建筑寻路
func _build_town_navigation(layout: TownLayout, def: CityDef) -> void:
	var grid: GeneratedGrid = layout.roads_grid
	var bg: GeneratedGrid = layout.build_grid
	var w := grid.width
	var d := grid.height
	var walkable := {}
	for z in d:
		for x in w:
			if grid.get_cell(x, z, -1) != 0 or bg.get_cell(x, z, -1) == def.building_floor_value:
				walkable[Vector2i(x, z)] = true
	var nav_grid := GeneratedGrid3D.create(w, 3, d, 0)
	for z in d:
		for x in w:
			var c := Vector2i(x, z)
			if bg.get_cell(x, z, -1) == def.building_wall_value:
				for y in 3:
					nav_grid.set_cell(x, y, z, 1)
			elif walkable.has(c):
				nav_grid.set_cell(x, 0, z, 1)
	NavBridgeTool.setup_navigation_3d(nav_region, nav_grid, 1, Vector3(-w / 2.0, -0.8, -d / 2.0), 0.45, 0.5)
	_test_town_navigation(layout, def)


func _test_town_navigation(layout: TownLayout, def: CityDef) -> void:
	await get_tree().create_timer(0.6).timeout
	if not is_inside_tree():
		return
	if layout.buildings.size() < 2:
		return
	var map := nav_region.get_navigation_map()
	var mesh := nav_region.navigation_mesh
	if mesh.get_vertices().size() < 3 or mesh.get_polygon_count() < 1:
		_log_tail("导航网格为空（无可走面）")
		return
	var off := Vector3(-layout.roads_grid.width / 2.0 + 0.5, 0.3, -layout.roads_grid.height / 2.0 + 0.5)
	var a_door: Vector2i = layout.buildings[0].door
	var b_door: Vector2i = layout.buildings[layout.buildings.size() - 1].door
	var a := NavigationServer3D.map_get_closest_point(map, Vector3(a_door.x, 0, a_door.y) + off)
	var b := NavigationServer3D.map_get_closest_point(map, Vector3(b_door.x, 0, b_door.y) + off)
	var path := NavigationServer3D.map_get_path(map, a, b, true)
	_log_tail("导航烘焙：顶点 %d ／ 多边形 %d ／ 门到门寻路 %s (%d 点)" % [
		mesh.get_vertices().size(), mesh.get_polygon_count(),
		"OK" if path.size() > 1 else "FAIL", path.size(),
	])


func _log(msg: String) -> void:
	log_box.text = msg


func _add_box(center: Vector3, size: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = StandardMaterial3D.new()
	bm.material.albedo_color = color
	mi.mesh = bm
	mi.position = center
	world.add_child(mi)
