extends Control

## 三层架构 Demo —— ECS 与 Godot 配合的完整方案
##
##  ① 海量实体(长期方案): 2 万点阵, ECS 数据直读渲染, 不建 Node
##  ② 关键实体(中期方案): 10 个小兵, EntityView + NodeLink + ECSSyncSystem
##  ③ 交互(配合逻辑): 拖拽小兵 → 位置写回 ECS
##
## 运行: F5 运行 Scenes/ECS/EntityViewDemo.tscn

## —— ① 海量实体参数 ——
@export var crowd_count: int = 20000

## —— ② 关键实体参数 ——
@export var squad_count: int = 10

@onready var stats_label: Label = %StatsLabel
@onready var world_root: Node2D = %WorldRoot
@onready var crowd_cloud: ECSPointCloud = %CrowdCloud
@onready var save_button: Button = %SaveButton
@onready var load_button: Button = %LoadButton
@onready var destroy_button: Button = %DestroyButton
@onready var respawn_button: Button = %RespawnButton

var world: ECSWorld
var views: Array[EntityView] = []
var _dragging: EntityView = null
var _frame := 0


func _ready() -> void:
	save_button.pressed.connect(_on_save_pressed)
	load_button.pressed.connect(_on_load_pressed)
	destroy_button.pressed.connect(_on_destroy_pressed)
	respawn_button.pressed.connect(_on_respawn_pressed)
	_setup_world()
	_spawn_crowd()      # ① 海量点阵
	_spawn_squad()      # ② 关键实体
	_update_stats()


func _setup_world() -> void:
	world = ECSWorld.new(false)
	world.register_component(ECSDemoMoveComponent)
	world.register_component(HealthComponent)
	world.register_component(NodeLink)
	# 中期方案核心: ECSSyncSystem 批量同步位置(一个系统处理全部关键实体)
	world.register_system(ECSSyncSystem.new(), 10)
	# 可选: 移动系统(展示 ECS 驱动)
	world.register_system(ECSMoveSystem.new(), 20)


## ① 海量实体: 点阵渲染直读(长期方案, 不建 Node)
func _spawn_crowd() -> void:
	var n := crowd_count
	for i in n:
		var e := world.create_entity()
		world.add_component(e, ECSDemoMoveComponent)
		var angle := randf() * TAU
		var speed := 20.0 + randf() * 50.0
		world.set_field(e, ECSDemoMoveComponent, &"pos",
				Vector2(randf_range(20.0, 1130.0), randf_range(20.0, 700.0)))
		world.set_field(e, ECSDemoMoveComponent, &"vel", Vector2(cos(angle), sin(angle)) * speed)
	# 点阵抽样显示
	var step := ceili(crowd_count / 4000.0)
	crowd_cloud.set_sample_step(step)
	crowd_cloud.set_color(Color(0.35, 0.45, 0.9, 0.8))


## ② 关键实体: EntityView + NodeLink + SyncSystem
func _spawn_squad() -> void:
	for i in squad_count:
		var view := EntityView.spawn(world, null, Vector2.ZERO, world_root)
		view.name = "Unit_%d" % i
		view.add_component(ECSDemoMoveComponent)
		view.add_component(HealthComponent)
		view.bind_pos(ECSDemoMoveComponent, &"pos")
		view.set_field(ECSDemoMoveComponent, &"pos",
				Vector2(randf_range(80.0, 1070.0), randf_range(80.0, 640.0)))
		var color := Color.from_hsv(randf(), 0.7, 0.9)
		view.set_field(ECSDemoMoveComponent, &"color", color)
		view.set_field(HealthComponent, &"hp", 100)
		# 表现节点: 大号方块
		var block := ColorRect.new()
		block.size = Vector2(26, 26)
		block.color = color
		block.mouse_filter = Control.MOUSE_FILTER_IGNORE
		view.node = block
		view.node.position = Vector2.ZERO
		world_root.add_child(view.node)
		view.sync_ecs_to_node()
		world_root.add_child(view)
		views.append(view)


func _process(delta: float) -> void:
	if world == null:
		return
	# ECS 驱动: 移动系统(海量点阵 + 关键实体都动)
	world.tick(delta)
	# 边界回弹
	_bounce_all()
	# 点阵刷新(海量实体渲染直读)
	_frame += 1
	if _frame % 3 == 0:
		var pos: PackedVector2Array = world.get_column(ECSDemoMoveComponent, &"pos")
		crowd_cloud.set_points(pos)
		_update_stats()


func _bounce_all() -> void:
	var pos: PackedVector2Array = world.get_column(ECSDemoMoveComponent, &"pos")
	var vel: PackedVector2Array = world.get_column(ECSDemoMoveComponent, &"vel")
	var n := mini(pos.size(), vel.size())
	var changed := false
	for i in n:
		if pos[i].x < 15.0 or pos[i].x > 1135.0:
			vel[i].x = -vel[i].x
			pos[i].x = clampf(pos[i].x, 15.0, 1135.0)
			changed = true
		if pos[i].y < 15.0 or pos[i].y > 705.0:
			vel[i].y = -vel[i].y
			pos[i].y = clampf(pos[i].y, 15.0, 705.0)
			changed = true
	if changed:
		world.set_column(ECSDemoMoveComponent, &"pos", pos)
		world.set_column(ECSDemoMoveComponent, &"vel", vel)


## ③ 交互: 点击拖拽(节点 → ECS 写回)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = _pick_at(event.position)
		else:
			_dragging = null
	elif event is InputEventMouseMotion and _dragging != null:
		_dragging.node.position = event.position
		_dragging.sync_node_to_ecs()


func _pick_at(pos: Vector2) -> EntityView:
	var hit: EntityView = null
	var best := 40.0 * 40.0
	for v in views:
		if v.node == null or not world.is_alive(v.entity_id):
			continue
		var p: Vector2 = world.get_field(v.entity_id, ECSDemoMoveComponent, &"pos")
		var d := p.distance_squared_to(pos)
		if d < best:
			best = d
			hit = v
	return hit


## —— 按钮 ——

func _on_save_pressed() -> void:
	# 只存关键实体数据(海量点阵是运行时生成的, 不存档)
	var data := world.serialize()
	var err := SaveTool.save_data("user://ecs_demo_save.dat", data, SaveTool.Mode.GZIP)
	stats_label.text += "\n[存档] %s" % ("成功" if err == OK else "失败: %d" % err)


func _on_load_pressed() -> void:
	_clear_squad()
	var data = SaveTool.load_data("user://ecs_demo_save.dat", SaveTool.Mode.GZIP)
	if data == null:
		stats_label.text += "\n[读档] 无存档"
		return
	var entity_ids: Array = world.deserialize(data)
	# 重建关键实体节点(带 NodeLink 的才是关键实体)
	for eid in entity_ids:
		if not world.has_component(eid, NodeLink):
			continue
		var view := EntityView.new()
		view.world = world
		view.entity_id = eid
		view.name = "Unit_%d" % eid
		view.bind_pos(ECSDemoMoveComponent, &"pos")
		var saved_color: Color = world.get_field(eid, ECSDemoMoveComponent, &"color")
		var block := ColorRect.new()
		block.size = Vector2(26, 26)
		block.color = saved_color
		block.mouse_filter = Control.MOUSE_FILTER_IGNORE
		view.node = block
		view.node.position = Vector2.ZERO
		world_root.add_child(view.node)
		view.sync_ecs_to_node()
		world_root.add_child(view)
		views.append(view)
	stats_label.text += "\n[读档] 重建 %d 个关键实体" % views.size()


func _on_destroy_pressed() -> void:
	_clear_squad()


func _on_respawn_pressed() -> void:
	_clear_squad()
	_spawn_squad()
	_update_stats()


func _clear_squad() -> void:
	for v in views:
		v.destroy()
	views.clear()


func _update_stats() -> void:
	var alive := 0
	for v in views:
		if world.is_alive(v.entity_id):
			alive += 1
	stats_label.text = "ECS 三层架构 Demo\n\n① 海量实体(点阵): %d\n② 关键实体(节点): %d (存活 %d)\n\n🖱 拖拽小兵 → 写回 ECS(双向同步)\n💾 存档 / 📂 读档\n\n[用法] 海量用渲染直读, 关键用 EntityView+SyncSystem" % [
		crowd_count, views.size(), alive]
