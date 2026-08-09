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
var _pos_use_xyz: bool = false
var _x_field: StringName = &"x"
var _y_field: StringName = &"y"
var _z_field: StringName = &"z"


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


## —— ECS↔Node 桥接: 把本节点作为数据组件注册进 ECS ——
## 反射本节点脚本的 @export 纯数据变量作为组件 schema, 注册并写入当前值(同 Entity2D)。
func register_to_ecs() -> bool:
	if ecs.world == null:
		push_warning("Entity3D(%s): 未设置 world, 无法注册到 ECS。" % name)
		return false
	ecs.world.register_component(get_script())
	if not ecs.add_component(self):
		return false
	_auto_bind_position()
	return true


## 自动绑定位置字段: 组件 schema 含 Vector3 pos(或 x+y+z)时记录, 供 sync_ecs_to_node/sync_node_to_ecs 使用。
func _auto_bind_position() -> void:
	var schema: Dictionary = ECSNative.collect_schema(self, true)
	var has := {}
	for f in schema.get("fields", []):
		has[f.name] = true
	if has.has("pos"):
		bind_pos(get_script(), &"pos")
	elif has.has("x") and has.has("y") and has.has("z"):
		bind_pos_xyz(get_script(), &"x", &"y", &"z")


func is_bound() -> bool:
	return ecs.is_bound()


func destroy() -> void:
	ecs.destroy()


## —— 位置同步(ECS ↔ 节点, Vector3) ——
## 适用于单实体/低频同步(关键实体、交互时)。海量批量请用列直读(get_column)循环赋值。

func bind_pos(component: Script, field: StringName = &"pos") -> void:
	_pos_comp = component
	_pos_field = field
	_pos_use_xyz = false


func bind_pos_xyz(component: Script, x_field: StringName = &"x", y_field: StringName = &"y", z_field: StringName = &"z") -> void:
	_pos_comp = component
	_pos_use_xyz = true
	_x_field = x_field
	_y_field = y_field
	_z_field = z_field


## ECS → 节点
func sync_ecs_to_node() -> void:
	if _pos_comp == null:
		return
	position = _read_ecs_position()


## 节点 → ECS
func sync_node_to_ecs() -> void:
	if _pos_comp == null or ecs.entity_id < 0:
		return
	if _pos_use_xyz:
		ecs.set_field(_pos_comp, _x_field, position.x)
		ecs.set_field(_pos_comp, _y_field, position.y)
		ecs.set_field(_pos_comp, _z_field, position.z)
	else:
		ecs.set_field(_pos_comp, _pos_field, position)


func _read_ecs_position() -> Vector3:
	if _pos_use_xyz:
		return Vector3(ecs.get_field(_pos_comp, _x_field),
				ecs.get_field(_pos_comp, _y_field), ecs.get_field(_pos_comp, _z_field))
	var v = ecs.get_field(_pos_comp, _pos_field)
	if v is Vector3:
		return v
	if v is Vector2:
		return Vector3(v.x, v.y, 0)
	return Vector3.ZERO
