extends Node3D
## 3D NPC 巡逻演示 — PCG 栅格 → NavigationMesh 桥接 + Godot 自带 NavigationAgent3D
##
## 1. 用 PCGTool 生成小地表地形（GeneratedGrid3D）并体素化渲染
## 2. setup_navigation_3d 把栅格桥接成 Godot 导航网格
## 3. 放 3 个 NPC（NavigationAgent3D）自动巡逻，实时展示引擎原生连续寻路
## 鼠标左键拖拽旋转查看。

@export var grid3d_defs: Array[Resource] = []
@export var npc_count := 3

@onready var camera: Camera3D = %Camera3D
@onready var world: Node3D = %World
@onready var npc_layer: Node3D = %NPCLayer
@onready var player_layer: Node3D = %PlayerLayer
@onready var obstacle_layer: Node3D = %ObstacleLayer
@onready var algo_option: OptionButton = %AlgoOption
@onready var seed_spin: SpinBox = %SeedSpin
@onready var log_box: RichTextLabel = %LogBox
@onready var nav_region: NavigationRegion3D = %NavRegion3D

var _yaw := 0.7
var _pitch := 0.25
var _npcs: Array[Node] = []
var _player: Node3D


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
	var size := 24.0
	var dist := size * 1.3 + 4.0
	var pos := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * dist
	camera.position = pos
	camera.look_at(Vector3.ZERO, Vector3.UP)


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
	var grid := PCGTool.generate_grid_3d(def, PCGTool.make_rng(int(seed_spin.value)))
	_render(grid, def)
	_build_navigation(grid, def)
	_spawn_npcs(grid, def)
	var solid := grid.count(def.solid_value)
	var empty := grid.cells.size() - solid
	_log("NPC 三态 AI + RVO 避障演示：%s  %dx%dx%d\n实体 %d ／ 空 %d\n玩家WASD移动(绿)，障碍物方向键移动(黄)，NPC 巡逻/追逐/逃跑并自动避让" % [
		def.name, grid.width, grid.height, grid.depth, solid, empty,
	])


func _render(grid: GeneratedGrid3D, def: Grid3DGenDef) -> void:
	for child in world.get_children():
		child.queue_free()
	var origin := Vector3(-grid.width / 2.0, -grid.height / 2.0, -grid.depth / 2.0)
	var pts := PackedVector3Array()
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
			pts.append(Vector3(x, y, z) + origin)
	if pts.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1, 1, 1)
	var mat := StandardMaterial3D.new()
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


func _build_navigation(grid: GeneratedGrid3D, def: Grid3DGenDef) -> void:
	var origin := Vector3(-grid.width / 2.0, -grid.height / 2.0, -grid.depth / 2.0)
	NavBridgeTool.setup_navigation_3d(nav_region, grid, def.solid_value, origin, 0.5, 0.25)


func _spawn_npcs(grid: GeneratedGrid3D, def: Grid3DGenDef) -> void:
	for child in npc_layer.get_children():
		child.queue_free()
	_npcs.clear()
	if grid == null:
		return
	# 收集可走面中心点作为出生/巡逻中心（实体格顶面上方）
	var centers: Array[Vector3] = []
	for i in grid.cells.size():
		var v := grid.cells[i]
		if v != def.empty_value:
			continue
		var x := i % grid.width
		var y := (i / grid.width) % grid.height
		var z := i / (grid.width * grid.height)
		if grid.get_cell(x, y - 1, z, -1) != def.solid_value:
			continue
		centers.append(Vector3(x - grid.width / 2.0, y - grid.height / 2.0, z - grid.depth / 2.0))
	if centers.is_empty():
		_log("无可用出生点")
		return
	var rng := PCGTool.make_rng(int(seed_spin.value) + 99)
	_spawn_player(centers, rng)
	_spawn_obstacles(centers, rng)
	var npc_scene: PackedScene = preload("res://Scenes/PCG/NavPatrolNPC.tscn")
	for i in npc_count:
		var c := centers[rng.randi_range(0, centers.size() - 1)]
		var npc: Node3D = npc_scene.instantiate()
		npc.position = c
		npc.patrol_center = c
		npc.patrol_radius = 6.0
		npc.chase_range = 9.0
		npc.flee_range = 2.5
		npc.avoidance_enabled = true
		npc_layer.add_child(npc)
		if _player:
			npc.target = _player
		_npcs.append(npc)


## 生成动态障碍物（NavigationObstacle3D，方向键移动，NPC 会 RVO 避让）
func _spawn_obstacles(centers: Array, rng: RandomNumberGenerator) -> void:
	for child in obstacle_layer.get_children():
		child.queue_free()
	if centers.size() < 2:
		return
	var obstacle_scene: PackedScene = preload("res://Scenes/PCG/NavObstacle.tscn")
	var obs := obstacle_scene.instantiate()
	obs.position = centers[rng.randi_range(0, centers.size() - 1)]
	obstacle_layer.add_child(obs)


## 生成玩家角色（NPC 追逐/逃跑目标），WASD 移动
func _spawn_player(centers: Array, rng: RandomNumberGenerator) -> void:
	for child in player_layer.get_children():
		child.queue_free()
	if centers.is_empty():
		_player = null
		return
	var player_scene: PackedScene = preload("res://Scenes/PCG/NavPlayer.tscn")
	_player = player_scene.instantiate()
	_player.position = centers[rng.randi_range(0, centers.size() - 1)]
	player_layer.add_child(_player)


func _log(msg: String) -> void:
	log_box.text = msg


const _DIR6: Array[Vector3i] = [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
]
