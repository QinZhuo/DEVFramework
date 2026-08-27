extends Node3D
## PCG 3D 演示 · 体素地形 / 洞穴
##
## 生成 GeneratedGrid3D 并用 MultiMesh 体素化显示，鼠标左键拖拽旋转查看。
## 算法与 2D 相同思想（噪声高度图 / 细胞自动机），验证 PCG 的 3D 基石。

@export var grid3d_defs: Array[Resource] = []
## 城镇生成的地形高度图(默认山地=复杂地形验证; 置 null 可切平地)。运行时可由外部赋值注入。
@export var town_heightmap_def: HeightMapDef = preload("res://Assets/Def/PCG/HeightMap_Mountain.tres")

@onready var camera: Camera3D = %Camera3D
@onready var world: Node3D = %World
@onready var algo_option: OptionButton = %AlgoOption
@onready var seed_spin: SpinBox = %SeedSpin
@onready var log_box: RichTextLabel = %LogBox
@onready var nav_region: NavigationRegion3D = %NavRegion3D

var _yaw := 0.7
var _pitch := 0.25
## 滚轮缩放系数（0.35 近景 ~ 2.5 远景）
var _zoom := 1.0
## 城镇模式巡逻 NPC（消费 TownLayout 门位数据做街头行走演示）
var _npc: CharacterBody3D = null
var _npc_agent: NavigationAgent3D = null
var _npc_targets := PackedVector3Array()
var _npc_idx := 0
## 夜景模式（N 键切换：夜空+暗环境光，窗灯/路灯/招牌/广告牌自发光主导）
var _night := false
## 干道车流（沿 ARTERIAL 折线循环行驶的低多边形汽车）
var _traffic_cars: Array = []
## 最近一次生成的城镇布局（S/L 存档热键的数据源）
var _last_layout: TownLayout = null


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
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom = clampf(_zoom * 0.88, 0.35, 2.5)
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom = clampf(_zoom * 1.14, 0.35, 2.5)
			_update_camera()
	elif event is InputEventKey and event.pressed:
		if event.keycode == KEY_N:
			_toggle_night()
		elif event.keycode == KEY_S and _last_layout != null:
			var err := SaveTool.save_data("user://save/town_demo.save", _last_layout.to_data(), SaveTool.Mode.GZIP)
			_log_tail("存档 %s (%s)" % ["OK" if err == OK else "失败", "user://save/town_demo.save"])
		elif event.keycode == KEY_L:
			var data = SaveTool.load_data("user://save/town_demo.save", SaveTool.Mode.GZIP)
			if data is Dictionary:
				var tl := TownLayout.from_data(data)
				if def_of_current() is TownDef:
					_render_town(tl, def_of_current())
					_build_town_navigation(tl, def_of_current())
					_log_tail("读档 OK: 建筑 %d" % tl.buildings.size())
			else:
				_log_tail("无存档可加载")


## 当前选中的 Def（供存档加载后重渲染）
func def_of_current() -> Resource:
	return _selected_res()


func _update_camera() -> void:
	var size := maxf(1.0, _current_size())
	var dist := size * 1.3 * _zoom
	var pos := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * dist
	camera.position = pos
	camera.look_at(Vector3.ZERO, Vector3.UP)


func _current_size() -> float:
	var res := _selected_res()
	if res is TownDef:
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
	if res is TownDef:
		_set_title("PCG 3D 演示 · 城镇")
		_gen_town_3d(res as TownDef)
		return
	_despawn_town_npc()
	_set_title("PCG 3D 演示 · 体素")
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


func _add_mesh_sized(pts: PackedVector3Array, color: Color, size: Vector3, transparent := false, emission := Color(0, 0, 0), roughness := -1.0) -> void:
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
	if roughness >= 0.0:
		mat.roughness = roughness
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

func _gen_town_3d(def: TownDef) -> void:
	var t0 := Time.get_ticks_usec()
	# 复杂地形: 注入 town_heightmap_def 即可让城镇贴地生成(坡度A*主街/切台/桩基/回写)
	var hm: HeightMap = null
	if town_heightmap_def != null:
		hm = PCGTool.generate_heightmap(town_heightmap_def, PCGTool.make_rng(int(seed_spin.value)))
	var layout := PCGTool.generate_town(def, hm, int(seed_spin.value))
	_last_layout = layout
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_render_town(layout, def)
	_build_town_navigation(layout, def)
	_update_camera()
	var poi := 0
	for b in layout.buildings:
		if String(b.type) != "住宅":
			poi += 1
	_log("城镇 3D: %s\n建筑 %d (设施 %d)｜地块 %d｜环路 %d 格\n生成 %.0fms ／ 拖拽旋转·滚轮缩放·N键夜景" % [
		layout.town_name if not layout.town_name.is_empty() else def.name,
		layout.buildings.size(), poi, layout.parcels.size(),
		layout.roads_grid.count(def.road_ring_value), ms,
	])


## TownLayout 三层栅格 → MultiMesh 体块（地形起伏贴地 + 道路/建筑/家具 分组着色）
func _render_town(layout: TownLayout, def: TownDef) -> void:
	for child in world.get_children():
		child.queue_free()
	var grid: GeneratedGrid = layout.roads_grid
	var bg: GeneratedGrid = layout.build_grid
	var w := grid.width
	var d := grid.height
	var hs := def.height_scale
	var hm := layout.heightmap
	# 天空盒+环境光（城镇模式专用氛围）
	var env := get_node_or_null("Env") as WorldEnvironment
	_apply_sky(_night)
	# 格坐标 → 世界坐标（y 取地表高度；无高度图时为 0）
	var to_world := func(x: int, z: int) -> Vector3:
		var h: float = hm.sample(x, z) if hm != null else 0.0
		return Vector3(x - w / 2.0 + 0.5, h * hs, z - d / 2.0 + 0.5)
	# 地形柱：按高度分层着色(草→岩→雪), 周边自然地貌变化一目了然; 每格一根贴地柱
	if hm != null:
		var sea_y := def.sea_level * hs
		var band_grass := PackedVector3Array()
		var band_grass_h := PackedFloat32Array()
		var band_rock := PackedVector3Array()
		var band_rock_h := PackedFloat32Array()
		var band_peak := PackedVector3Array()
		var band_peak_h := PackedFloat32Array()
		for z in d:
			for x in w:
				var h01: float = hm.sample(x, z)
				var wp: Vector3 = to_world.call(x, z)
				var col_h: float = maxf(0.35, h01 * hs)
				if h01 < def.sea_level:
					# 水下格压低为浅滩色
					band_grass.append(wp)
					band_grass_h.append(maxf(0.2, col_h * 0.4))
				elif h01 < def.sea_level + 0.18:
					band_grass.append(wp)
					band_grass_h.append(col_h)
				elif h01 < def.sea_level + 0.38:
					band_rock.append(wp)
					band_rock_h.append(col_h)
				else:
					band_peak.append(wp)
					band_peak_h.append(col_h)
		var mats := {
			"grass": [band_grass, band_grass_h, Color(0.46, 0.6, 0.33)],
			"rock": [band_rock, band_rock_h, Color(0.52, 0.48, 0.44)],
			"peak": [band_peak, band_peak_h, Color(0.82, 0.84, 0.88)],
		}
		for key in mats:
			var pts: PackedVector3Array = mats[key][0]
			if pts.is_empty():
				continue
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			var mesh := BoxMesh.new()
			mesh.size = Vector3(1, 1, 1)
			mesh.material = StandardMaterial3D.new()
			mesh.material.albedo_color = mats[key][2]
			mm.mesh = mesh
			mm.instance_count = pts.size()
			var hs_arr: PackedFloat32Array = mats[key][1]
			for i in pts.size():
				var col_h: float = hs_arr[i]
				mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(1, col_h, 1)), pts[i] - Vector3(0, col_h * 0.5 - 0.05, 0)))
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			world.add_child(mmi)
		# 海平面水面(半透明蓝, 山地自然出现湖泊/海湾)
		var water := MeshInstance3D.new()
		var wmesh := BoxMesh.new()
		wmesh.size = Vector3(w, 0.25, d)
		var wmat := StandardMaterial3D.new()
		wmat.albedo_color = Color(0.18, 0.4, 0.65, 0.8)
		wmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		wmesh.material = wmat
		water.mesh = wmesh
		water.position = Vector3(0, sea_y - 0.12, 0)
		world.add_child(water)
	else:
		var ground := MeshInstance3D.new()
		var gm := BoxMesh.new()
		gm.size = Vector3(w, 0.2, d)
		gm.material = StandardMaterial3D.new()
		gm.material.albedo_color = Color(0.46, 0.6, 0.33)
		ground.mesh = gm
		ground.position = Vector3(0, -0.1, 0)
		world.add_child(ground)
	# 道路层（按值分组；厚铺装半嵌入地形, 遮住格间台阶缝隙避免破碎感）
	# 沥青色阶整体加深、拉开等级对比(干道最深→巷道最浅偏土色), 与草地/人行道强对比
	var road_style := {
		def.road_arterial_value: [Color(0.22, 0.23, 0.26), 1.0],
		def.road_main_value: [Color(0.3, 0.31, 0.34), 0.9],
		def.road_sec_value: [Color(0.38, 0.39, 0.42), 0.75],
		def.road_alley_value: [Color(0.47, 0.45, 0.4), 0.65],
		def.road_ring_value: [Color(0.26, 0.27, 0.3), 0.75],
		def.bridge_value: [Color(0.42, 0.28, 0.16), 0.9],
	}
	for v in road_style:
		var pts := PackedVector3Array()
		for z in d:
			for x in w:
				if grid.get_cell(x, z, -1) == int(v):
					pts.append(to_world.call(x, z))
		_add_mesh_sized(pts, road_style[v][0], Vector3(1, float(road_style[v][1]), 1))
	# 主街中央黄色虚线 / 干道双黄实线 / 斑马线:
	# 全部先按 octilinear 两段式展开 road_edges 折线(与道路印刷一致), 标线才不脱轨
	var dash_h := PackedVector3Array()
	var dash_v := PackedVector3Array()
	var dbl_y_h := PackedVector3Array()
	var dbl_y_v := PackedVector3Array()
	var zebra_h := PackedVector3Array()
	var zebra_v := PackedVector3Array()
	var line_seen := {}
	for e in layout.road_edges:
		if int(e.cls) != TownLayout.EdgeClass.MAIN and int(e.cls) != TownLayout.EdgeClass.ARTERIAL:
			continue
		var is_art := int(e.cls) == TownLayout.EdgeClass.ARTERIAL
		var a := layout.road_nodes[int(e.a)]
		var bp := layout.road_nodes[int(e.b)]
		var poly := _octi_expand(a, bp)
		var horiz := absf(bp.x - a.x) >= absf(bp.y - a.y)
		# 展开 poly 为整数格中心序列(去重)
		var cells: Array = []
		for s in poly.size() - 1:
			var pa := poly[s]
			var pb := poly[s + 1]
			var steps := maxi(1, int(pa.distance_to(pb) * 2.0))
			for k in steps + (1 if s == poly.size() - 2 else 0):
				var gp := Vector2i(roundf(lerpf(pa.x, pb.x, float(k) / float(steps))), roundf(lerpf(pa.y, pb.y, float(k) / float(steps))))
				if cells.is_empty() or cells[cells.size() - 1] != gp:
					cells.append(gp)
				# 斑马线入口检测(仅干道, 每格一次)
				if is_art and not line_seen.has(gp):
					line_seen[gp] = true
					var hwz := int(e.width) / 2
					var cross := false
					for sz in [-hwz - 1, hwz + 1]:
						var v: int
						if horiz:
							v = grid.get_cell(gp.x, gp.y + sz, -1)
						else:
							v = grid.get_cell(gp.x + sz, gp.y, -1)
						if v != 0 and v != def.road_arterial_value and v != def.bridge_value:
							cross = true
					if cross:
						for st in 7:
							var o := -1.8 + float(st) * 0.6
							if absf(o) > float(hwz):
								break
							if horiz:
								zebra_h.append(to_world.call(gp.x, gp.y) + Vector3(0, 0.52, o))
							else:
								zebra_v.append(to_world.call(gp.x, gp.y) + Vector3(o, 0.52, 0))
		# 主街虚线: 沿格序列隔一放一
		if not is_art:
			for ci in range(0, cells.size(), 2):
				var gp2: Vector2i = cells[ci]
				var wp: Vector3 = to_world.call(gp2.x, gp2.y) + Vector3(0, 0.52, 0)
				if horiz:
					dash_h.append(wp)
				else:
					dash_v.append(wp)
		else:
			# 干道双黄实线: 每格两条平行线
			for ci in cells.size():
				var gp3: Vector2i = cells[ci]
				var base3: Vector3 = to_world.call(gp3.x, gp3.y)
				if horiz:
					dbl_y_h.append(base3 + Vector3(0, 0.56, -0.62))
					dbl_y_h.append(base3 + Vector3(0, 0.56, 0.62))
				else:
					dbl_y_v.append(base3 + Vector3(-0.62, 0.56, 0))
					dbl_y_v.append(base3 + Vector3(0.62, 0.56, 0))
	_add_mesh_sized(dash_h, Color(1.0, 0.85, 0.2), Vector3(0.78, 0.09, 0.24), false, Color(1.0, 0.85, 0.2))
	_add_mesh_sized(dash_v, Color(1.0, 0.85, 0.2), Vector3(0.24, 0.09, 0.78), false, Color(1.0, 0.85, 0.2))
	_add_mesh_sized(dbl_y_h, Color(1.0, 0.8, 0.1), Vector3(1.0, 0.09, 0.13), false, Color(1.0, 0.8, 0.1))
	_add_mesh_sized(dbl_y_v, Color(1.0, 0.8, 0.1), Vector3(0.13, 0.09, 1.0), false, Color(1.0, 0.8, 0.1))
	_add_mesh_sized(zebra_h, Color(0.92, 0.92, 0.88), Vector3(0.5, 0.07, 0.34), false, Color(0.7, 0.7, 0.68))
	_add_mesh_sized(zebra_v, Color(0.92, 0.92, 0.88), Vector3(0.34, 0.07, 0.5), false, Color(0.7, 0.7, 0.68))
	# 人行道：主街/干道/环路/次街邻接空格（浅灰白, 半嵌入）——全路网勾边, 道路轮廓一眼可辨
	var sidewalk_src := {
		def.road_main_value: true, def.road_arterial_value: true,
		def.road_ring_value: true, def.road_sec_value: true,
	}
	var sidewalk_seen := {}
	var walk_pts := PackedVector3Array()
	for z in d:
		for x in w:
			if not sidewalk_src.has(grid.get_cell(x, z, -1)):
				continue
			for dd: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx := x + dd.x
				var nz := z + dd.y
				if not grid.in_bounds(nx, nz) or sidewalk_seen.has(Vector2i(nx, nz)):
					continue
				if grid.get_cell(nx, nz, -1) == 0 and bg.get_cell(nx, nz, -1) == 0:
					sidewalk_seen[Vector2i(nx, nz)] = true
					walk_pts.append(to_world.call(nx, nz))
	_add_mesh_sized(walk_pts, Color(0.68, 0.66, 0.6), Vector3(1, 0.3, 1))
	# 广场
	var plaza_pts := PackedVector3Array()
	for idx in layout.plaza_cells:
		plaza_pts.append(to_world.call(int(idx) % w, int(idx) / w))
	_add_mesh_sized(plaza_pts, Color(0.6, 0.58, 0.52), Vector3(1, 0.14, 1))
	# 广场中心设施按语义分型（水井/喷泉/市集台）+ 四角市场摊位
	if layout.plaza_center.x >= 0 and not layout.plaza_item.is_empty():
		var pcw: Vector3 = to_world.call(layout.plaza_center.x, layout.plaza_center.y)
		var pitem := String(layout.plaza_item)
		if pitem.contains("井"):
			_add_box(pcw + Vector3(0, 0.3, 0), Vector3(1.7, 0.6, 1.7), Color(0.52, 0.5, 0.46))
			_add_box(pcw + Vector3(0, 0.62, 0), Vector3(1.05, 0.12, 1.05), Color(0.1, 0.14, 0.2))
			_add_box(pcw + Vector3(-0.66, 1.35, 0), Vector3(0.13, 1.5, 0.13), Color(0.4, 0.28, 0.16))
			_add_box(pcw + Vector3(0.66, 1.35, 0), Vector3(0.13, 1.5, 0.13), Color(0.4, 0.28, 0.16))
			_add_box(pcw + Vector3(0, 2.18, 0), Vector3(1.9, 0.16, 1.2), Color(0.45, 0.24, 0.14))
		elif pitem.contains("泉"):
			_add_box(pcw + Vector3(0, 0.22, 0), Vector3(2.6, 0.44, 2.6), Color(0.55, 0.53, 0.48))
			_add_box(pcw + Vector3(0, 0.46, 0), Vector3(2.1, 0.08, 2.1), Color(0.25, 0.5, 0.75))
			_add_box(pcw + Vector3(0, 0.85, 0), Vector3(0.4, 1.3, 0.4), Color(0.58, 0.56, 0.5))
			_add_box(pcw + Vector3(0, 1.55, 0), Vector3(1.1, 0.14, 1.1), Color(0.52, 0.5, 0.46))
			_add_box(pcw + Vector3(0, 1.64, 0), Vector3(0.8, 0.06, 0.8), Color(0.3, 0.55, 0.78))
			_add_mesh_sized(PackedVector3Array([pcw + Vector3(0, 1.9, 0)]),
					Color(0.75, 0.88, 1.0), Vector3(0.28, 0.55, 0.28), false, Color(0.5, 0.7, 0.9))
		else:
			_add_box(pcw + Vector3(0, 0.25, 0), Vector3(1.6, 0.35, 1.6), Color(0.52, 0.5, 0.46))
			_add_box(pcw + Vector3(0, 1.1, 0), Vector3(0.55, 1.7, 0.55), Color(0.62, 0.6, 0.56))
			_add_box(pcw + Vector3(0, 2.1, 0), Vector3(0.9, 0.22, 0.9), Color(0.45, 0.43, 0.4))
		# 市场摊位: 十字四向 3 格处的空地摆彩色顶棚小摊
		var canopy_cols := [Color(0.78, 0.25, 0.2), Color(0.2, 0.42, 0.72)]
		for k in 4:
			var off: Vector2i = [Vector2i(3, 0), Vector2i(-3, 0), Vector2i(0, 3), Vector2i(0, -3)][k]
			var scell: Vector2i = layout.plaza_center + off
			if not grid.in_bounds(scell.x, scell.y):
				continue
			if grid.get_cell(scell.x, scell.y, -1) != 0 or bg.get_cell(scell.x, scell.y, -1) != 0:
				continue
			var sp: Vector3 = to_world.call(scell.x, scell.y)
			_add_box(sp + Vector3(0, 0.5, 0), Vector3(1.6, 0.16, 1.2), Color(0.5, 0.34, 0.18))
			_add_box(sp + Vector3(-0.7, 1.0, -0.5), Vector3(0.12, 1.1, 0.12), Color(0.4, 0.28, 0.16))
			_add_box(sp + Vector3(0.7, 1.0, -0.5), Vector3(0.12, 1.1, 0.12), Color(0.4, 0.28, 0.16))
			_add_box(sp + Vector3(-0.7, 1.0, 0.5), Vector3(0.12, 1.1, 0.12), Color(0.4, 0.28, 0.16))
			_add_box(sp + Vector3(0.7, 1.0, 0.5), Vector3(0.12, 1.1, 0.12), Color(0.4, 0.28, 0.16))
			_add_box(sp + Vector3(0, 1.62, 0), Vector3(1.9, 0.2, 1.4), canopy_cols[k % 2])
			_add_mesh_sized(PackedVector3Array([sp + Vector3(-0.35, 0.68, 0), sp + Vector3(0.35, 0.68, 0)]),
					Color(0.85, 0.78, 0.4), Vector3(0.34, 0.3, 0.34))
	# 建筑：墙体按 (类型,层数,风格) 分组——y 全部基于 ground_y 切台基准；地板/门/窗/屋顶贴地
	var wall_groups := {}  # key → pts（中心已含 ground_y）
	var wall_set_of := {}  # b.id → 本建筑墙格集合
	var floors := PackedVector3Array()
	var win_along_x := PackedVector3Array()
	var win_along_z := PackedVector3Array()
	var door_along_x := PackedVector3Array()
	var door_along_z := PackedVector3Array()
	for b in layout.buildings:
		var is_fac := String(b.type) != "住宅"
		var rect: Rect2i = b.rect
		var blayers: int = int(b.layers)
		var gy: float = float(b.ground_y) * hs
		var top_h := blayers * 1.5 + 0.9
		var gkey := ("F_" if is_fac else "H_") + str(blayers) + "_" + String(b.style)
		if not wall_groups.has(gkey):
			wall_groups[gkey] = PackedVector3Array()
		var wpts: PackedVector3Array = wall_groups[gkey]
		var wall_set: Dictionary = {}
		for yy in range(rect.position.y, rect.end.y):
			for xx in range(rect.position.x, rect.end.x):
				var cv := bg.get_cell(xx, yy, -1)
				var c := Vector2i(xx, yy)
				var base: Vector3 = to_world.call(xx, yy)
				# 关键修复: 建筑构件 Y 一律锚定切台基准 gy,
				# 此前用原始地形高导致山地建筑墙/地板/窗整体错位"飞到房顶"
				base.y = gy
				if cv == def.building_wall_value:
					wall_set[c] = true
					wpts.append(base + Vector3(0, top_h * 0.5 - 0.1, 0))
				elif cv == def.building_floor_value:
					floors.append(base + Vector3(0, 0.08, 0))
		# 定向门板（贴地、朝向正确）
		var dr: Vector2i = b.door
		var dp: Vector3 = to_world.call(dr.x, dr.y) + Vector3(0, 1.25, 0)
		dp.y = gy + 1.25
		if int(b.facing) == 1 or int(b.facing) == 3:
			door_along_x.append(dp)
		else:
			door_along_z.append(dp)
		var dvec: Vector2i = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)][posmod(int(b.facing), 4)]
		# 门口雨棚: 门板上方外挑小檐(木色)
		var awc: Vector3 = to_world.call(dr.x, dr.y)
		awc.y = gy
		awc += Vector3(dvec.x * 0.78, 2.6, dvec.y * 0.78)
		if dvec.x != 0:
			_add_box(awc, Vector3(0.6, 0.16, 1.5), Color(0.36, 0.22, 0.12))
		else:
			_add_box(awc, Vector3(1.5, 0.16, 0.6), Color(0.36, 0.22, 0.12))
		# 沿干道商铺: 底层通长骑楼雨廊 + 二层彩色招牌横条(商业街界面)
		if String(b.type) == "商铺":
			var ex := (rect.end.x - 1) if dvec.x > 0 else rect.position.x
			var ey := (rect.end.y - 1) if dvec.y > 0 else rect.position.y
			var ec: Vector3 = to_world.call(
					ex if dvec.x != 0 else rect.get_center().x,
					rect.get_center().y if dvec.x != 0 else ey)
			ec.y = gy
			var edge_len := float(rect.size.y) if dvec.x != 0 else float(rect.size.x)
			var sign_col: Color = [
				Color(0.85, 0.3, 0.25), Color(0.2, 0.55, 0.8),
				Color(0.9, 0.65, 0.15), Color(0.35, 0.6, 0.35),
			][posmod(int(b.id), 4)]
			if dvec.x != 0:
				_add_box(ec + Vector3(dvec.x * 0.42, 2.62, 0), Vector3(0.72, 0.14, edge_len * 0.96), Color(0.34, 0.21, 0.12))
				_add_box(ec + Vector3(dvec.x * 0.58, 3.25, 0), Vector3(0.16, 0.72, edge_len * 0.86), sign_col, sign_col * 0.3)
			else:
				_add_box(ec + Vector3(0, 2.62, dvec.y * 0.42), Vector3(edge_len * 0.96, 0.14, 0.72), Color(0.34, 0.21, 0.12))
				_add_box(ec + Vector3(0, 3.25, dvec.y * 0.58), Vector3(edge_len * 0.86, 0.72, 0.16), sign_col, sign_col * 0.3)
		# 发光窗：每层一排、棋盘间隔、贴暴露面外侧(wy 为相对 gy 的偏移, 勿再加第二次基准高)
		for row in maxi(1, blayers):
			var wy := 1.15 + row * 1.5
			for yy in range(rect.position.y, rect.end.y):
				for xx in range(rect.position.x, rect.end.x):
					if not wall_set.has(Vector2i(xx, yy)) or (xx + yy + row) % 2 == 1:
						continue
					for dd: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
						if not wall_set.has(Vector2i(xx + dd.x, yy + dd.y)):
							var wbase: Vector3 = to_world.call(xx, yy)
							wbase.y = gy
							var wp: Vector3 = wbase + Vector3(dd.x * 0.53, wy, dd.y * 0.53)
							if dd.x != 0:
								win_along_x.append(wp)
							else:
								win_along_z.append(wp)
							break
		# 屋顶按语义类型 + 风格色：gable 双坡(檐+脊)；flat 平顶女儿墙
		var roof_pair: Array = {
			"木构": [Color(0.5, 0.22, 0.14), Color(0.56, 0.28, 0.17)],
			"石砌": [Color(0.42, 0.46, 0.58), Color(0.48, 0.52, 0.62)],
			"砖混": [Color(0.45, 0.2, 0.16), Color(0.52, 0.26, 0.2)],
			"混凝土": [Color(0.5, 0.51, 0.53), Color(0.58, 0.59, 0.61)],
			"玻璃幕墙": [Color(0.35, 0.48, 0.6), Color(0.42, 0.58, 0.7)],
		}.get(String(b.style), [Color(0.46, 0.19, 0.13), Color(0.54, 0.24, 0.16)])
		var rc: Vector3 = to_world.call(rect.get_center().x, rect.get_center().y)
		rc.y = gy
		if String(b.roof) == "flat":
			_add_box(rc + Vector3(0, top_h + 0.18, 0),
					Vector3(rect.size.x + 0.2, 0.35, rect.size.y + 0.2),
					Color(0.4, 0.44, 0.52) if is_fac else (roof_pair[0] as Color).lightened(0.1))
			# 平顶屋顶设施(附属房/水箱): 天际线高低错落
			if int(b.id) % 3 == 0:
				_add_box(rc + Vector3(rect.size.x * 0.2, top_h + 0.75, -rect.size.y * 0.16),
						Vector3(maxf(1.2, rect.size.x * 0.4), 1.1, maxf(1.2, rect.size.y * 0.4)),
						Color(0.48, 0.46, 0.42))
			elif int(b.id) % 3 == 1:
				_add_box(rc + Vector3(-rect.size.x * 0.22, top_h + 0.85, rect.size.y * 0.18),
						Vector3(0.6, 1.3, 0.6), Color(0.55, 0.56, 0.58))
		else:
			var eave_size := Vector3(rect.size.x + 0.6, 0.24, rect.size.y + 0.6)
			var ridge_size := Vector3(maxf(1.0, rect.size.x * 0.55), 0.5, maxf(1.0, rect.size.y * 0.55))
			_add_box(rc + Vector3(0, top_h + 0.12, 0), eave_size,
					(roof_pair[1] as Color).lightened(0.25) if is_fac else roof_pair[0])
			_add_box(rc + Vector3(0, top_h + 0.48, 0), ridge_size,
					(roof_pair[1] as Color).lightened(0.2) if is_fac else roof_pair[1])
			# 砖砌烟囱: 坡顶建筑四角之一(按 id 确定性选角), 高出屋脊; 教堂用钟楼替代
			if String(b.type) != "教堂":
				var ox := 0 if int(b.id) % 2 == 0 else maxi(0, rect.size.x - 2)
				var oz := 0 if (int(b.id) / 2) % 2 == 0 else maxi(0, rect.size.y - 2)
				var cpos: Vector3 = to_world.call(rect.position.x + ox, rect.position.y + oz)
				cpos.y = gy
				_add_box(cpos + Vector3(0, top_h + 0.45, 0), Vector3(0.42, 1.9, 0.42), Color(0.42, 0.26, 0.2))
				_add_box(cpos + Vector3(0, top_h + 1.46, 0), Vector3(0.52, 0.14, 0.52), Color(0.3, 0.19, 0.15))
		# 教堂钟楼: 临街角部收分塔身 + 金色顶, 全镇制高点
		if String(b.type) == "教堂":
			var tc2 := Vector2i(
					rect.position.x if dvec.x <= 0 else rect.end.x - 1,
					rect.position.y if dvec.y <= 0 else rect.end.y - 1)
			var tpos: Vector3 = to_world.call(tc2.x, tc2.y)
			tpos.y = gy
			var stone_c := Color(0.58, 0.58, 0.55)
			_add_box(tpos + Vector3(0, 2.4, 0), Vector3(1.5, 4.8, 1.5), stone_c)
			_add_box(tpos + Vector3(0, 5.15, 0), Vector3(1.1, 1.1, 1.1), stone_c.lightened(0.12))
			_add_box(tpos + Vector3(0, 6.1, 0), Vector3(0.66, 0.9, 0.66), stone_c.lightened(0.24))
			_add_box(tpos + Vector3(0, 6.85, 0), Vector3(0.32, 0.7, 0.32), Color(0.85, 0.72, 0.3))
		if String(b.foundation) == "stilt":
			for corner in [rect.position, Vector2i(rect.end.x - 1, rect.position.y),
					Vector2i(rect.position.x, rect.end.y - 1), rect.end - Vector2i.ONE]:
				var base2: Vector3 = to_world.call(corner.x, corner.y)
				var pillar_h := maxf(0.5, gy - base2.y + 0.6)
				_add_box(Vector3(base2.x, base2.y + pillar_h * 0.5, base2.z),
						Vector3(0.28, pillar_h, 0.28), Color(0.32, 0.23, 0.14))
	for gkey in wall_groups:
		var is_fac_g: bool = String(gkey).begins_with("F_")
		var ln: int = int(String(gkey).get_slice("_", 1))
		var sname: String = String(gkey).get_slice("_", 2)
		var col: Color = {
			"木构": Color(0.36, 0.23, 0.14),
			"石砌": Color(0.55, 0.55, 0.52),
			"砖混": Color(0.5, 0.28, 0.2),
		}.get(sname, Color(0.36, 0.23, 0.14))
		if is_fac_g:
			col = col.lightened(0.25)
		var rough: float = {"木构": 0.9, "石砌": 0.6, "砖混": 0.78}.get(sname, 0.85)
		_add_mesh_sized(wall_groups[gkey], col, Vector3(1, ln * 1.5 + 0.9, 1), false, Color(0, 0, 0), rough)
	_add_mesh_sized(floors, Color(0.62, 0.48, 0.3), Vector3(1, 0.1, 1))
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
	# 树木(深绿柱冠) / 路灯(灯杆+发光灯头) / 长椅(矮褐凳)
	var tree_crown := PackedVector3Array()
	var tree_trunk := PackedVector3Array()
	for t in layout.trees:
		tree_trunk.append(to_world.call(t.x, t.y) + Vector3(0, 0.5, 0))
		tree_crown.append(to_world.call(t.x, t.y) + Vector3(0, 1.4, 0))
	_add_mesh_sized(tree_trunk, Color(0.32, 0.22, 0.12), Vector3(0.25, 1.0, 0.25))
	_add_mesh_sized(tree_crown, Color(0.16, 0.38, 0.14), Vector3(1.3, 1.6, 1.3))
	# 灌木绿带(干道两侧低矮绿化)
	var bush_pts := PackedVector3Array()
	for bsh in layout.bushes:
		bush_pts.append(to_world.call(bsh.x, bsh.y) + Vector3(0, 0.26, 0))
	_add_mesh_sized(bush_pts, Color(0.2, 0.42, 0.16), Vector3(0.78, 0.52, 0.78))
	var lamp_pole := PackedVector3Array()
	var lamp_head := PackedVector3Array()
	for lamp in layout.streets.get("lamps", []):
		var lv: Vector2i = lamp
		lamp_pole.append(to_world.call(lv.x, lv.y) + Vector3(0, 0.9, 0))
		lamp_head.append(to_world.call(lv.x, lv.y) + Vector3(0, 1.95, 0))
	_add_mesh_sized(lamp_pole, Color(0.3, 0.32, 0.35), Vector3(0.15, 1.8, 0.15))
	var lamp_glow := Color(1.0, 0.85, 0.45)
	_add_mesh_sized(lamp_head, lamp_glow, Vector3(0.4, 0.3, 0.4), false, lamp_glow)
	var bench_pts := PackedVector3Array()
	for bench in layout.streets.get("benches", []):
		var bv: Vector2i = bench
		bench_pts.append(to_world.call(bv.x, bv.y))
	_add_mesh_sized(bench_pts, Color(0.36, 0.24, 0.14), Vector3(0.8, 0.4, 0.8))
	# 垃圾桶(深绿桶身+桶盖)
	var bin_body := PackedVector3Array()
	var bin_lid := PackedVector3Array()
	for bn in layout.streets.get("bins", []):
		var bp: Vector3 = to_world.call(bn.x, bn.y)
		bin_body.append(bp + Vector3(0, 0.36, 0))
		bin_lid.append(bp + Vector3(0, 0.78, 0))
	_add_mesh_sized(bin_body, Color(0.3, 0.34, 0.38), Vector3(0.42, 0.72, 0.42))
	_add_mesh_sized(bin_lid, Color(0.2, 0.23, 0.26), Vector3(0.48, 0.09, 0.48))
	# 公交站: 站台+立柱+顶棚+站牌 (朝向按相邻干道格推断)
	for stop in layout.streets.get("bus_stops", []):
		var sp: Vector2i = stop
		var base: Vector3 = to_world.call(sp.x, sp.y)
		var out := Vector3.ZERO
		for dd in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if grid.get_cell(sp.x + dd.x, sp.y + dd.y, -1) == def.road_arterial_value:
				out = Vector3(-dd.x, 0, -dd.y)
				break
		var plat_c: Vector3 = base + out * 0.25
		_add_box(plat_c + Vector3(0, 0.14, 0), Vector3(1.5 if absf(out.z) > 0 else 2.6, 0.28, 2.6 if absf(out.z) > 0 else 1.5), Color(0.72, 0.72, 0.7))
		var post_off := Vector3(0, 0, 0.55) if absf(out.x) > 0 else Vector3(0.55, 0, 0)
		_add_box(base + out * 0.55 + post_off + Vector3(0, 1.15, 0), Vector3(0.1, 2.3, 0.1), Color(0.35, 0.38, 0.42))
		_add_box(base + out * 0.55 - post_off + Vector3(0, 1.15, 0), Vector3(0.1, 2.3, 0.1), Color(0.35, 0.38, 0.42))
		_add_box(base + out * 0.62 + Vector3(0, 2.4, 0),
				Vector3(1.8 if absf(out.z) > 0 else 2.9, 0.12, 2.9 if absf(out.z) > 0 else 1.8), Color(0.22, 0.28, 0.36))
		var sign_dir := out
		_add_box(base + sign_dir * 0.15 + Vector3(0, 1.35, 0) + (Vector3(0.5, 0, 0) if absf(out.z) > 0 else Vector3(0, 0, 0.5)),
				Vector3(0.12, 1.05, 0.7) if absf(out.z) > 0 else Vector3(0.7, 1.05, 0.12), Color(0.2, 0.55, 0.95))
	# 消防栓(红色小柱+顶帽)
	var hyd_body := PackedVector3Array()
	var hyd_cap := PackedVector3Array()
	for hd in layout.streets.get("hydrants", []):
		var hp: Vector3 = to_world.call(hd.x, hd.y)
		hyd_body.append(hp + Vector3(0, 0.28, 0))
		hyd_cap.append(hp + Vector3(0, 0.6, 0))
	_add_mesh_sized(hyd_body, Color(0.78, 0.15, 0.1), Vector3(0.26, 0.56, 0.26))
	_add_mesh_sized(hyd_cap, Color(0.85, 0.25, 0.18), Vector3(0.34, 0.12, 0.34))
	# 广告牌: 双柱+大板面(彩色拼条, 垂直元素)
	for adb in layout.streets.get("adboards", []):
		var ap: Vector3 = to_world.call(adb.x, adb.y)
		_add_box(ap + Vector3(-0.55, 0.75, 0), Vector3(0.14, 1.5, 0.14), Color(0.32, 0.32, 0.36))
		_add_box(ap + Vector3(0.55, 0.75, 0), Vector3(0.14, 1.5, 0.14), Color(0.32, 0.32, 0.36))
		var board_cols := [Color(0.9, 0.35, 0.3), Color(0.25, 0.5, 0.85)]
		for half in [-1, 1]:
			var bc: Color = board_cols[(half + 1) / 2]
			_add_box(ap + Vector3(float(half) * 0.72, 1.95, 0),
					Vector3(1.42, 1.5, 0.12), bc, bc * 0.35)
			_add_box(ap + Vector3(float(half) * 0.72, 2.76, 0), Vector3(1.46, 0.08, 0.16), Color(0.92, 0.92, 0.9))
	# 农田条纹（两种作物色薄板交替）
	var crop_a := PackedVector3Array()
	var crop_b := PackedVector3Array()
	for farm in layout.farms:
		for idx in farm:
			var fx := int(idx) % layout.roads_grid.width
			var fz := int(idx) / layout.roads_grid.width
			if (fx + fz) % 4 < 2:
				crop_a.append(to_world.call(fx, fz))
			else:
				crop_b.append(to_world.call(fx, fz))
	_add_mesh_sized(crop_a, Color(0.55, 0.5, 0.2), Vector3(1, 0.08, 1))
	_add_mesh_sized(crop_b, Color(0.45, 0.42, 0.16), Vector3(1, 0.12, 1))
	# 选址标记柱
	var site_mark := PackedVector3Array([to_world.call(layout.site.x, layout.site.y)])
	_add_mesh_sized(site_mark, Color(1.0, 0.25, 0.1), Vector3(1.2, 6.0, 1.2))
	_spawn_town_traffic(layout, to_world)


## 干道车流: 邻接表重建干道链(交叉节点不再跳链) + 每段按道路印刷同款八向展开
## (干道是 octilinear 路径, 直接连端点的直线会切角穿房——必须与 _octi_segment 展开一致)
func _spawn_town_traffic(layout: TownLayout, to_world: Callable) -> void:
	for c in _traffic_cars:
		(c.node as Node3D).queue_free()
	_traffic_cars.clear()
	var adj := {}
	for e in layout.road_edges:
		if int(e.cls) != TownLayout.EdgeClass.ARTERIAL:
			continue
		var ea := int(e.a)
		var eb := int(e.b)
		if not adj.has(ea):
			adj[ea] = {}
		if not adj.has(eb):
			adj[eb] = {}
		(adj[ea] as Dictionary)[eb] = true
		(adj[eb] as Dictionary)[ea] = true
	if adj.is_empty():
		return
	# 从度=1 端点出发走链(交叉节点不跳链); 全是环时任取起点
	var starts: Array = []
	for n in adj.keys():
		if (adj[n] as Dictionary).size() == 1:
			starts.append(n)
	if starts.is_empty():
		starts.append(adj.keys()[0])
	var chains: Array = []
	var visited := {}
	for n0 in starts:
		var cur: int = n0
		var prev := -1
		var chain := PackedInt32Array([cur])
		while true:
			var nxt := -1
			for nb in adj[cur]:
				var ek := Vector2i(mini(cur, int(nb)), maxi(cur, int(nb)))
				if int(nb) != prev and not visited.has(ek):
					nxt = int(nb)
					break
			if nxt < 0:
				break
			visited[Vector2i(mini(cur, nxt), maxi(cur, nxt))] = true
			chain.append(nxt)
			prev = cur
			cur = nxt
		if chain.size() >= 2:
			chains.append(chain)
	for chain in chains:
		var pts := PackedVector3Array()
		for i in chain.size() - 1:
			var a: Vector2 = layout.road_nodes[chain[i]]
			var b: Vector2 = layout.road_nodes[chain[i + 1]]
			var poly := _octi_expand(a, b)
			var keep := poly.size() if i == chain.size() - 2 else poly.size() - 1
			for k in keep:
				var p: Vector2 = poly[k]
				pts.append(to_world.call(int(roundf(p.x)), int(roundf(p.y))) + Vector3(0, 0.55, 0))
		var total := 0.0
		var cum := PackedFloat32Array([0.0])
		for i in range(1, pts.size()):
			total += pts[i - 1].distance_to(pts[i])
			cum.append(total)
		if total < 12.0:
			continue
		for dir_sign in [1, -1]:
			var car := Node3D.new()
			var body_col: Color = [Color(0.92, 0.22, 0.16), Color(0.18, 0.5, 0.9), Color(0.95, 0.78, 0.15), Color(0.94, 0.94, 0.96)][absi(hash(chain[0]) + dir_sign) % 4]
			_add_car_part(car, Vector3(0, 0.55, 0), Vector3(2.4, 0.7, 1.35), body_col)
			_add_car_part(car, Vector3(-0.15, 1.12, 0), Vector3(1.3, 0.55, 1.15), Color(0.12, 0.15, 0.2))
			_add_car_part(car, Vector3(0.88, 0.85, 0), Vector3(0.2, 0.2, 0.08), Color(1.0, 0.95, 0.6), Color(1.0, 0.9, 0.45))
			world.add_child(car)
			_traffic_cars.append({
				"node": car, "pts": pts, "cum": cum, "total": total,
				"dist": total * (0.5 if dir_sign > 0 else 0.48),
				"speed": 5.5 if dir_sign > 0 else 5.0,
				"reverse": dir_sign < 0,
				"lane": -0.62 * dir_sign,
			})


func _add_car_part(parent: Node3D, pos: Vector3, size: Vector3, color: Color, emission := Color(0, 0, 0)) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = StandardMaterial3D.new()
	bm.material.albedo_color = color
	if emission.a > 0.0:
		bm.material.emission_enabled = true
		bm.material.emission = emission
	mi.mesh = bm
	mi.position = pos
	parent.add_child(mi)


## 沿折线取位置与朝向 (dist 归一化到 [0,total))
func _traffic_sample(pts: PackedVector3Array, cum: PackedFloat32Array, total: float, dist: float) -> Dictionary:
	var dd := fposmod(dist, total)
	var i := 1
	while i < cum.size() and cum[i] < dd:
		i += 1
	i = mini(i, cum.size() - 1)
	var t0 := cum[i - 1]
	var seg_len := maxf(0.001, cum[i] - t0)
	var t := (dd - t0) / seg_len
	var a := pts[i - 1]
	var b := pts[i]
	return {"pos": a.lerp(b, t), "dir": (b - a).normalized()}


## 城镇导航：可行走面 = 道路/广场/室内地板，墙体为实体障碍；
## 有高度图时按真实地表高度分层（NavBridge 找顶面逻辑天然适配）
func _build_town_navigation(layout: TownLayout, def: TownDef) -> void:
	var grid: GeneratedGrid = layout.roads_grid
	var bg: GeneratedGrid = layout.build_grid
	var w := grid.width
	var d := grid.height
	var hm := layout.heightmap
	var hs := def.height_scale
	var layers := int(hs) + 4 if hm != null else 3
	var walkable := {}
	for z in d:
		for x in w:
			if grid.get_cell(x, z, -1) != 0 or bg.get_cell(x, z, -1) == def.building_floor_value:
				walkable[Vector2i(x, z)] = true
	var nav_grid := GeneratedGrid3D.create(w, layers, d, 0)
	for z in d:
		for x in w:
			var c := Vector2i(x, z)
			var gh := int(round((hm.sample(x, z) * hs) if hm != null else 0.0))
			if bg.get_cell(x, z, -1) == def.building_wall_value:
				for ly in range(gh, mini(layers, gh + 4)):
					nav_grid.set_cell(x, ly, z, 1)
			elif walkable.has(c):
				for ly in range(0, mini(layers, gh + 1)):
					nav_grid.set_cell(x, ly, z, 1)
	NavBridgeTool.setup_navigation_3d(nav_region, nav_grid, 1,
			Vector3(-w / 2.0, -1.0, -d / 2.0), 0.45, 0.5)
	_test_town_navigation(layout, def)


func _test_town_navigation(layout: TownLayout, def: TownDef) -> void:
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
	_spawn_town_npc(layout, def)


## 巡逻 NPC：胶囊小人沿各建筑门位循环行走（验证导航面在真实移动下的可用性）
func _spawn_town_npc(layout: TownLayout, def: TownDef) -> void:
	_despawn_town_npc()
	if layout.buildings.size() < 2:
		return
	var off := Vector3(-layout.roads_grid.width / 2.0 + 0.5, 0.2, -layout.roads_grid.height / 2.0 + 0.5)
	_npc = CharacterBody3D.new()
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.55
	cap.height = 2.0
	col.shape = cap
	_npc.add_child(col)
	var mi := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.55
	cm.height = 2.0
	cm.material = StandardMaterial3D.new()
	cm.material.albedo_color = Color(1.0, 0.5, 0.15)
	mi.mesh = cm
	mi.position.y = 1.05
	_npc.add_child(mi)
	_npc_agent = NavigationAgent3D.new()
	_npc_agent.radius = 0.5
	_npc.add_child(_npc_agent)
	world.add_child(_npc)
	for b in layout.buildings:
		var dr: Vector2i = b.door
		_npc_targets.append(Vector3(dr.x, 0, dr.y) + off)
	_npc.global_position = _npc_targets[0] + Vector3(0, 0.6, 0)
	_npc_idx = 1 % _npc_targets.size()
	_npc_agent.target_position = _npc_targets[_npc_idx]


func _despawn_town_npc() -> void:
	if _npc != null and is_instance_valid(_npc):
		_npc.queue_free()
	_npc = null
	_npc_agent = null
	_npc_targets = PackedVector3Array()


func _physics_process(delta: float) -> void:
	# 干道车流推进(沿折线循环, 右侧车道偏移)
	for car in _traffic_cars:
		var node: Node3D = car.node
		if not is_instance_valid(node):
			continue
		var total: float = car.total
		car.dist = fposmod(car.dist + car.speed * delta, total)
		var s := _traffic_sample(car.pts, car.cum, total, car.dist)
		var dir: Vector3 = s.dir
		if car.reverse:
			dir = -dir
		var side := Vector3(-dir.z, 0, dir.x)
		node.position = s.pos + side * float(car.lane) * -1.0
		node.look_at(node.position + dir, Vector3.UP)
		node.rotation.x = 0.0
		node.rotation.z = 0.0
	if _npc == null or _npc_agent == null or not is_instance_valid(_npc):
		return
	if _npc_agent.is_navigation_finished():
		_npc_idx = (_npc_idx + 1) % _npc_targets.size()
		_npc_agent.target_position = _npc_targets[_npc_idx]
		return
	var next := _npc_agent.get_next_path_position()
	var dir := next - _npc.global_position
	dir.y = 0.0
	if dir.length() > 0.05:
		_npc.velocity = dir.normalized() * 3.0
		_npc.move_and_slide()


func _add_box(center: Vector3, size: Vector3, color: Color, emission := Color(0, 0, 0)) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = StandardMaterial3D.new()
	bm.material.albedo_color = color
	if emission.a > 0.0:
		bm.material.emission_enabled = true
		bm.material.emission = emission
	mi.mesh = bm
	mi.position = center
	world.add_child(mi)


## octilinear 两段式展开(与 PCGTool._octi_segment 一致): 标线沿实际道路折线撒点不脱轨
func _octi_expand(a: Vector2, b: Vector2) -> PackedVector2Array:
	var dx := b.x - a.x
	var dy := b.y - a.y
	var adx := absf(dx)
	var ady := absf(dy)
	var out := PackedVector2Array([a])
	if adx > ady:
		out.append(Vector2(a.x + dx - signf(dx) * ady, a.y))
	elif ady > adx:
		out.append(Vector2(a.x, a.y + dy - signf(dy) * adx))
	out.append(b)
	return out


## 天空/环境光：白天=蓝天+强环境光；夜景(N 键)=深夜蓝+暗环境+冷月光, 自发光元素主导
func _apply_sky(night: bool) -> void:
	var env := get_node_or_null("Env") as WorldEnvironment
	var sun := get_node_or_null("Sun") as DirectionalLight3D
	if sun:
		sun.light_color = Color(0.55, 0.65, 1.0) if night else Color.WHITE
		sun.light_energy = 0.35 if night else 1.5
	if not env:
		return
	var sky := Sky.new()
	var smat := ProceduralSkyMaterial.new()
	if night:
		smat.sky_top_color = Color(0.02, 0.03, 0.09)
		smat.sky_horizon_color = Color(0.06, 0.08, 0.14)
		smat.ground_bottom_color = Color(0.01, 0.01, 0.03)
		smat.ground_horizon_color = Color(0.05, 0.06, 0.1)
		sky.sky_material = smat
		env.environment.background_mode = Environment.BG_SKY
		env.environment.sky = sky
		env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.environment.ambient_light_color = Color(0.17, 0.2, 0.32)
		env.environment.ambient_light_energy = 1.0
	else:
		smat.sky_top_color = Color(0.32, 0.52, 0.85)
		smat.sky_horizon_color = Color(0.72, 0.8, 0.9)
		smat.ground_bottom_color = Color(0.3, 0.33, 0.36)
		smat.ground_horizon_color = Color(0.66, 0.73, 0.82)
		sky.sky_material = smat
		env.environment.background_mode = Environment.BG_SKY
		env.environment.sky = sky
		env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.environment.ambient_light_energy = 1.3


func _toggle_night() -> void:
	_night = not _night
	_apply_sky(_night)


func _set_title(t: String) -> void:
	var label := get_node_or_null("UI/Panel/VBox/Title")
	if label != null:
		label.text = t


func _log(msg: String) -> void:
	log_box.text = msg
