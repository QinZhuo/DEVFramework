extends Control

## EntityView 演示 —— ECS 数据实体 ↔ Godot 场景节点 桥接
##
## 展示内容:
##   - 用 EntityView 创建 15 个"小兵"(ECS 实体 + 场景节点)
##   - ECS 系统算移动, EntityView 每帧把位置同步到场景节点
##   - 点击小兵可拖拽(双向同步: 节点位置写回 ECS)
##   - 按钮: 存档 / 读档(序列化演示)
##   - 按钮: 摧毁所有 / 重生
##
## 运行: F5 运行 Scenes/ECS/EntityViewDemo.tscn

@export var squad_count: int = 15

@onready var stats_label: Label = %StatsLabel
@onready var world_root: Node2D = %WorldRoot
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
	_spawn_squad()
	_update_stats()


func _setup_world() -> void:
	world = ECSWorld.new(false)
	world.register_component(ECSDemoMoveComponent)
	world.register_component(HealthComponent)
	# 静止模式: 不注册移动系统, 位置完全由拖动/存档/读档控制(便于验证桥接)


func _spawn_squad() -> void:
	for i in squad_count:
		var view := EntityView.spawn(world, null, Vector2.ZERO, false)
		view.name = "Unit_%d" % i
		view.add_component(ECSDemoMoveComponent)
		view.add_component(HealthComponent)
		view.bind_pos_vector(ECSDemoMoveComponent, &"pos")
		view.set_field(ECSDemoMoveComponent, &"pos",
				Vector2(randf_range(80.0, 1070.0), randf_range(80.0, 640.0)))
		# 初始静止(vel=0): 位置固定可观察, 拖动是主要交互
		view.set_field(ECSDemoMoveComponent, &"vel", Vector2.ZERO)
		var color := Color.from_hsv(randf(), 0.7, 0.9)
		view.set_field(ECSDemoMoveComponent, &"color", color)  # 颜色存组件, 读档可恢复
		view.set_field(HealthComponent, &"hp", 100)
		# 表现节点: 大号彩色方块(便于观察和点击)
		var block := ColorRect.new()
		block.size = Vector2(26, 26)
		block.color = color
		block.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 点击判定用独立的透明大区域(吸附方便)
		view.node = block  # 用 ColorRect 直接表现(挂到 Node2D 根下)
		view.node.position = Vector2.ZERO
		world_root.add_child(view.node)
		view._sync_ecs_to_node()
		world_root.add_child(view)
		views.append(view)


func _process(delta: float) -> void:
	if world == null:
		return
	# 静止模式: 不驱动移动, 只统计(位置由拖动/存档/读档控制, 便于验证)
	_frame += 1
	if _frame % 10 == 0:
		_update_stats()


## —— 交互: 点击拖拽(双向同步演示) ——
## 用 _input 而非 _unhandled_input: 根 Control 可能消费鼠标事件,
## 用 _input 保证在 GUI 处理前触发, 一定能收到。

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = _pick_at(event.position)
			if _dragging != null:
				# 双向: 拖拽时节点位置写回 ECS(每帧同步)
				_dragging.one_way = false
		else:
			if _dragging != null:
				_dragging.one_way = true
				_dragging = null
	elif event is InputEventMouseMotion and _dragging != null:
		_dragging.node.position = event.position
		_dragging.sync_node_to_ecs()  # 节点 → ECS 写回


func _pick_at(pos: Vector2) -> EntityView:
	# 用 ECS 位置 + 方块半径做命中检测(比 Control.rect 可靠)
	var hit: EntityView = null
	var best_dist := 40.0 * 40.0  # 40px 内可选中
	for v in views:
		if v.node == null or not world.is_alive(v.entity_id):
			continue
		var p: Vector2 = world.get_field(v.entity_id, ECSDemoMoveComponent, &"pos")
		var d := p.distance_squared_to(pos)
		if d < best_dist:
			best_dist = d
			hit = v
	return hit


## —— 按钮 ——

func _on_save_pressed() -> void:
	var data := world.serialize()
	# 用 GZIP 二进制存档: 保真 Vector2 等类型(JSON 会把 Vector2 存成字符串丢失类型)
	var err := SaveTool.save_data("user://ecs_demo_save.dat", data, SaveTool.Mode.GZIP)
	stats_label.text += "\n[存档] %s" % ("成功" if err == OK else "失败: %d" % err)


func _on_load_pressed() -> void:
	_clear_all()
	var data = SaveTool.load_data("user://ecs_demo_save.dat", SaveTool.Mode.GZIP)
	if data == null:
		stats_label.text += "\n[读档] 无存档"
		return
	# 反序列化重建实体数据, 返回真实实体 ID 列表
	var entity_ids: Array = world.deserialize(data)
	# 按真实实体 ID 重建表现节点
	for eid in entity_ids:
		var view := EntityView.new()
		view.world = world
		view.entity_id = eid  # 真实实体 ID(含 version 位)
		view.name = "Unit_%d" % eid
		view.bind_pos_vector(ECSDemoMoveComponent, &"pos")
		# 颜色从组件恢复(读档保持与存档一致)
		var saved_color: Color = world.get_field(eid, ECSDemoMoveComponent, &"color")
		var block := ColorRect.new()
		block.size = Vector2(26, 26)
		block.color = saved_color
		block.mouse_filter = Control.MOUSE_FILTER_IGNORE
		view.node = block
		view.node.position = Vector2.ZERO
		world_root.add_child(view.node)
		view._sync_ecs_to_node()
		world_root.add_child(view)
		views.append(view)
	stats_label.text += "\n[读档] 重建 %d 个实体" % entity_ids.size()


func _on_destroy_pressed() -> void:
	_clear_all()


func _on_respawn_pressed() -> void:
	_clear_all()
	_spawn_squad()
	_update_stats()


func _clear_all() -> void:
	for v in views:
		v.destroy()
	views.clear()


func _update_stats() -> void:
	var alive := 0
	for v in views:
		if world.is_alive(v.entity_id):
			alive += 1
	stats_label.text = "EntityView 桥接 Demo ｜ 小兵: %d\n\n🖱 点击拖拽小兵 → 位置写回 ECS(双向同步)\n💾 存档 / 📂 读档 → 序列化演示\n\n存活实体: %d / %d" % [
		views.size(), alive, views.size()]
