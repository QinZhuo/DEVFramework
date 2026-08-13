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
	var def := _selected_def()
	return maxf(maxf(def.width if def else 32, def.height if def else 32), def.depth if def else 32)


func _selected_def() -> Grid3DGenDef:
	if algo_option.selected < 0 or algo_option.selected >= grid3d_defs.size():
		return null
	return grid3d_defs[algo_option.selected] as Grid3DGenDef


func _on_regen_pressed() -> void:
	_generate()


func _generate() -> void:
	var def := _selected_def()
	if def == null:
		_log("请配置 grid3d_defs")
		return
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
	if pts.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1, 1, 1)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	if transparent:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
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


func _log(msg: String) -> void:
	log_box.text = msg
