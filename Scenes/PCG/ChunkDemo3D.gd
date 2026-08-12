extends Node3D
## PCG 3D 分块世界演示 · 无限体素世界 + 3D 散布
##
## 分块世界：ChunkedWorld3D 确定性懒加载 N³ 个 chunk，地表跨 chunk 连续；
## 3D 散布：PlacementDef3D 在 3D 空间散布点集。鼠标左键拖拽旋转。

enum Mode {
	CHUNK,
	PLACE,
}

@export var grid3d_defs: Array[Resource] = []
@export var placement3d_defs: Array[Resource] = []

@onready var camera: Camera3D = %Camera3D
@onready var world: Node3D = %World
@onready var mode_option: OptionButton = %ModeOption
@onready var sub_option: OptionButton = %SubOption
@onready var radius_spin: SpinBox = %RadiusSpin
@onready var seed_spin: SpinBox = %SeedSpin
@onready var log_box: RichTextLabel = %LogBox

var _yaw := 0.7
var _pitch := 0.25


func _ready() -> void:
	var labels := ["分块世界", "3D 散布"]
	for i in labels.size():
		mode_option.add_item(labels[i], i)
	mode_option.item_selected.connect(func(_i: int) -> void: _reload_sub())
	sub_option.item_selected.connect(func(_i: int) -> void: _generate())
	seed_spin.value_changed.connect(func(_v: float) -> void: _generate())
	_reload_sub()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_yaw -= event.relative.x * 0.008
		_pitch = clampf(_pitch - event.relative.y * 0.008, -1.45, 1.45)
		_update_camera()


func _reload_sub() -> void:
	sub_option.clear()
	var defs := grid3d_defs if mode_option.selected == Mode.CHUNK else placement3d_defs
	for i in defs.size():
		var d: Resource = defs[i]
		var label := d.resource_path.get_file().get_basename() if d and not d.resource_path.is_empty() else ("资源%d" % i)
		sub_option.add_item(label, i)
	radius_spin.visible = mode_option.selected == Mode.CHUNK
	_generate()


func _selected_defs() -> Array:
	return grid3d_defs if mode_option.selected == Mode.CHUNK else placement3d_defs


func _on_regen_pressed() -> void:
	_generate()


func _generate() -> void:
	_update_camera()
	if mode_option.selected == Mode.CHUNK:
		_gen_chunks()
	else:
		_gen_place()


func _gen_chunks() -> void:
	var def: Grid3DGenDef = null
	if sub_option.selected >= 0 and sub_option.selected < grid3d_defs.size():
		var cand: Resource = grid3d_defs[sub_option.selected]
		if cand is Grid3DGenDef:
			def = cand as Grid3DGenDef
	if def == null:
		_log("请配置 grid3d_defs")
		return
	var radius := int(radius_spin.value)
	var world_obj := ChunkedWorld3D.new()
	world_obj.seed_base = int(seed_spin.value)
	world_obj.grid3d_def = def
	world_obj.chunk_size = 8
	var t := Time.get_ticks_msec()
	var size := (radius * 2 + 1) * 8
	var center := Vector3(size / 2.0, size / 2.0, size / 2.0)
	var pts := PackedVector3Array()
	for cz in range(-radius, radius + 1):
		for cy in range(-radius, radius + 1):
			for cx in range(-radius, radius + 1):
				var g := world_obj.get_chunk(cx, cy, cz)
				_collect_pts(pts, g, def, Vector3(cx * 8, cy * 8, cz * 8), center)
	var ms := Time.get_ticks_msec() - t
	_render_voxels(pts, def)
	_log("3D 分块世界: %d 个 chunk（%d³ 体素） 耗时 %d ms\nseed=%d  鼠标左键拖拽旋转" % [
		world_obj.get_chunk_count(), size, ms, world_obj.seed_base,
	])


func _collect_pts(pts: PackedVector3Array, g: GeneratedGrid3D, def: Grid3DGenDef, base: Vector3, center: Vector3) -> void:
	var render_value := def.empty_value if def.type == Grid3DGenDef.Type.CAVE_3D else def.solid_value
	for i in g.cells.size():
		if g.cells[i] != render_value:
			continue
		var x := i % g.width
		var y := (i / g.width) % g.height
		var z := i / (g.width * g.height)
		var pos := base + Vector3(x, y, z) - center
		if def.type == Grid3DGenDef.Type.CAVE_3D:
			pts.append(pos)
			continue
		if y == 0:
			continue
		var exposed := false
		for d in _DIR6:
			if g.get_cell(x + d.x, y + d.y, z + d.z, def.empty_value) == def.empty_value:
				exposed = true
				break
		if exposed:
			pts.append(pos)


func _gen_place() -> void:
	var def: PlacementDef3D = null
	if sub_option.selected >= 0 and sub_option.selected < placement3d_defs.size():
		var cand: Resource = placement3d_defs[sub_option.selected]
		if cand is PlacementDef3D:
			def = cand as PlacementDef3D
	if def == null:
		_log("请配置 placement3d_defs")
		return
	var t := Time.get_ticks_msec()
	var pts := PCGTool.place_3d(def, PCGTool.make_rng(int(seed_spin.value)))
	var ms := Time.get_ticks_msec() - t
	_render_points(pts)
	_log("3D 散布: %s  生成 %d 点（%s）耗时 %d ms" % [
		def.name, pts.size(), PlacementDef3D.Mode.keys()[def.mode], ms,
	])


func _render_voxels(pts: PackedVector3Array, def: Grid3DGenDef) -> void:
	_clear_world()
	if pts.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1, 1, 1)
	var mat := StandardMaterial3D.new()
	if def.type == Grid3DGenDef.Type.CAVE_3D:
		mat.albedo_color = Color(0.3, 0.7, 0.85, 0.55)
	else:
		mat.albedo_color = Color(0.6, 0.65, 0.72)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = mat
	mm.mesh = mesh
	mm.instance_count = pts.size()
	for i in pts.size():
		mm.set_instance_transform(i, Transform3D(Basis(), pts[i]))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	world.add_child(mmi)


func _render_points(pts: PackedVector3Array) -> void:
	_clear_world()
	if pts.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var mesh := SphereMesh.new()
	mesh.radius = 0.4
	mesh.height = 0.8
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.7, 0.3)
	mesh.material = mat
	mm.mesh = mesh
	mm.instance_count = pts.size()
	for i in pts.size():
		mm.set_instance_transform(i, Transform3D(Basis(), pts[i] - Vector3(32, 16, 32)))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	world.add_child(mmi)


func _clear_world() -> void:
	for child in world.get_children():
		child.queue_free()


func _update_camera() -> void:
	var size := 20.0
	if mode_option.selected == Mode.CHUNK:
		size = (int(radius_spin.value) * 2 + 1) * 8
	var dist := size * 1.4 + 4.0
	var pos := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * dist
	camera.position = pos
	camera.look_at(Vector3.ZERO, Vector3.UP)


func _log(msg: String) -> void:
	log_box.text = msg


const _DIR6: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
