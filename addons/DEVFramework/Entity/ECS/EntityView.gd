class_name EntityView
extends Node

## EntityView —— ECS 实体与 Godot 场景节点的桥接。
##
## 连接两套世界:
##   - ECS 世界: Entity(整数 ID)持有纯数据组件(位置/速度/血量...)
##   - Godot 场景: Node(Node2D/Node3D/Sprite 等)负责渲染与交互
##
## EntityView 负责双向同步, 让逻辑在 ECS 里算, 表现走 Godot 节点:
##   - ECS 位置组件(pos) → node.position      (每帧自动)
##   - node 位置手动改  → ECS 位置组件        (可选, 默认单向)
##
## 用法:
##   var view = EntityView.spawn(world, player_scene, Vector2(100, 200))
##   view.entity_id          # 对应的 ECS 实体 ID
##   view.node               # 场景里的表现节点
##   view.set_pos_comp(&"pos")  # 配置: 用哪个组件字段当位置
##
##   view.free()  # 销毁: 同步移除 ECS 实体 + 场景节点

## 绑定的 ECS 世界
var world: ECSWorld

## 对应的 ECS 实体 ID
var entity_id: int = -1

## 表现节点(场景实例)
var node: Node

## 位置组件字段(可配置, 默认 ECSDemoMoveComponent.pos / MoveComponent 的 x,y)
var pos_comp: Script = null
var pos_field: StringName = &"pos"
var pos_use_xy: bool = false   # true 时用 x/y 两个 float 字段, false 用 Vector2/3 字段

## 同步方向: true = 只 ECS→节点; false = 双向
var one_way: bool = true

var _x_field: StringName = &"x"
var _y_field: StringName = &"y"
var _active := true


## 静态工厂: 创建 ECS 实体 + 实例化场景节点 + 绑定。
## world: ECS 世界; scene: PackedScene 或 Node; 
## pos: 初始世界坐标(可选); auto_bind: 是否立即挂到当前场景树
static func spawn(world: ECSWorld, scene, pos: Vector2 = Vector2.ZERO, auto_bind: bool = true) -> EntityView:
	var view := EntityView.new()
	view.world = world
	view.entity_id = world.create_entity()
	# 实例化表现节点
	if scene is PackedScene:
		view.node = scene.instantiate()
	elif scene is Node:
		view.node = scene
	else:
		view.node = Node2D.new()
	if view.node is Node2D:
		view.node.position = pos
	elif view.node is Node3D:
		view.node.position = Vector3(pos.x, pos.y, 0)
	if auto_bind and view.node != null and not view.node.is_inside_tree():
		var parent := _find_parent()
		if parent != null:
			parent.add_child(view.node)
	return view


static func _find_parent() -> Node:
	# 尝试从当前场景根挂载
	var scene := Engine.get_main_loop() as SceneTree
	if scene and scene.current_scene:
		return scene.current_scene
	return null


## 给实体附加组件(便捷封装)
func add_component(component, def_data: Dictionary = {}) -> bool:
	if world == null:
		return false
	return world.add_component(entity_id, component, def_data)


func has_component(component) -> bool:
	return world != null and world.has_component(entity_id, component)


func get_field(component, field: StringName):
	return world.get_field(entity_id, component, field) if world else null


func set_field(component, field: StringName, value) -> void:
	if world:
		world.set_field(entity_id, component, field, value)


## 配置位置组件映射: 用 Vector2/3 字段(如 pos)
func bind_pos_vector(component: Script, field: StringName = &"pos") -> void:
	pos_comp = component
	pos_field = field
	pos_use_xy = false


## 配置位置组件映射: 用两个 float 字段(如 x, y)
func bind_pos_xy(component: Script, x_field: StringName = &"x", y_field: StringName = &"y") -> void:
	pos_comp = component
	pos_use_xy = true
	_x_field = x_field
	_y_field = y_field


func _process(delta: float) -> void:
	if not _active or world == null or node == null:
		return
	# 单向模式(one_way=true): 每帧 ECS→节点
	# 双向模式(one_way=false): 停止自动同步, 由外部 sync_node_to_ecs() 手动写回
	if one_way:
		_sync_ecs_to_node()


## 取 ECS 位置 → Vector2
func _ecs_pos2() -> Vector2:
	if pos_use_xy:
		return Vector2(world.get_field(entity_id, pos_comp, _x_field),
				world.get_field(entity_id, pos_comp, _y_field))
	var v = world.get_field(entity_id, pos_comp, pos_field)
	if v is Vector2:
		return v
	if v is Vector3:
		return Vector2(v.x, v.y)
	return Vector2.ZERO


## ECS 位置 → 节点位置(支持 Node2D/Node3D/Control)
func _sync_ecs_to_node() -> void:
	if pos_comp == null:
		return
	var p := _ecs_pos2()
	if node is Node2D:
		node.position = p
	elif node is Control:
		node.position = p
	elif node is Node3D:
		node.position = Vector3(p.x, p.y, 0)


## 手动触发节点 → ECS 同步(双向模式用)
func sync_node_to_ecs() -> void:
	if pos_comp == null or node == null:
		return
	if pos_use_xy:
		if node is Node2D:
			world.set_field(entity_id, pos_comp, _x_field, node.position.x)
			world.set_field(entity_id, pos_comp, _y_field, node.position.y)
		elif node is Control:
			world.set_field(entity_id, pos_comp, _x_field, node.position.x)
			world.set_field(entity_id, pos_comp, _y_field, node.position.y)
		elif node is Node3D:
			world.set_field(entity_id, pos_comp, _x_field, node.position.x)
			world.set_field(entity_id, pos_comp, _y_field, node.position.z)
	else:
		var p: Vector2
		if node is Node2D:
			p = node.position
		elif node is Control:
			p = node.position
		elif node is Node3D:
			p = Vector2(node.position.x, node.position.z)
		world.set_field(entity_id, pos_comp, pos_field, p)


## 停用同步(不销毁)
func set_active(v: bool) -> void:
	_active = v
	set_process(v)


## 销毁: 移除 ECS 实体 + 释放表现节点
func destroy() -> void:
	_active = false
	if world != null and entity_id >= 0 and world.is_alive(entity_id):
		world.destroy_entity(entity_id)
	entity_id = -1
	if node != null and is_instance_valid(node):
		node.queue_free()
		node = null


func _exit_tree() -> void:
	# 场景卸载时兜底释放(不强制销毁实体, 由调用方控制)
	_active = false
