class_name Entity3D extends Node3D

## 3D 节点实体 —— ECS 实体 + Node3D 场景表现 + 可挂 Component 补充。
##
## 数据在 ECS 列, 本节点是门面/表现。位置可用 bind_pos 同步 ECS↔节点。
## 用法:
##   var e := Entity3D.new()
##   e.world = my_world
##   e.add_component(MoveComponent, {"pos": Vector3.ZERO})   # 数据进 ECS 列
##   e.bind_pos(MoveComponent, &"pos")                       # 位置同步(ECS Vector3)
##   e.sync_ecs_to_node()

## ECS 桥接(数据在 ECS 列, 懒创建 —— 只有用到 ecs 时才实例化)
var _ecs: ECSLink = null
var ecs: ECSLink:
	get:
		if _ecs == null:
			_ecs = ECSLink.new()
		return _ecs
	set(v):
		_ecs = v

## 便捷访问
var world: ECSWorld:
	get:
		return ecs.world
	set(v):
		ecs.world = v

var entity_id: int:
	get:
		return ecs.entity_id
	set(v):
		ecs.entity_id = v

# ---- 位置同步 ----
var _pos_comp: Script = null
var _pos_field: StringName = &"pos"


func _exit_tree() -> void:
	ecs.destroy()


## —— ECS 实体门面(便捷) ——

func add_component(comp: Script, values: Dictionary = {}) -> bool:
	return ecs.add_component(comp, values)


func has_component(comp) -> bool:
	return ecs.has_component(comp)


func get_field(comp, field: StringName):
	return ecs.get_field(comp, field)


func set_field(comp, field: StringName, value) -> void:
	ecs.set_field(comp, field, value)


## —— 传统属性路由(路线A): 直接读写 schema 字段自动进 ECS ——
## 仅当 ecs 已初始化(world 已设置)且字段属于已注册组件时才接管;
## 否则走默认逻辑, 保持懒加载。注意: schema 字段名勿与 Node3D 原生属性(position 等)重名。

func _set(property: StringName, value) -> bool:
	if _ecs == null:
		return false
	var owner: Script = _ecs.field_owner(property)
	if owner == null:
		return false
	_ecs.set_field(owner, property, value)
	return true


func _get(property: StringName):
	if _ecs == null:
		return null
	var owner: Script = _ecs.field_owner(property)
	if owner == null:
		return null
	return _ecs.get_field(owner, property)


func is_bound() -> bool:
	return ecs.is_bound()


func destroy() -> void:
	ecs.destroy()


## —— 位置同步(ECS ↔ 节点, Vector3) ——

func bind_pos(component: Script, field: StringName = &"pos") -> void:
	_pos_comp = component
	_pos_field = field


## ECS → 节点
func sync_ecs_to_node() -> void:
	if _pos_comp == null:
		return
	position = _ecs_pos3()


## 节点 → ECS
func sync_node_to_ecs() -> void:
	if _pos_comp == null or ecs.entity_id < 0:
		return
	ecs.set_field(_pos_comp, _pos_field, position)


func _ecs_pos3() -> Vector3:
	var v = ecs.get_field(_pos_comp, _pos_field)
	if v is Vector3:
		return v
	if v is Vector2:
		return Vector3(v.x, v.y, 0)
	return Vector3.ZERO
