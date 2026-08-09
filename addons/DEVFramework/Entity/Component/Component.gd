class_name Component extends Node

## 节点组件基类 —— 作为宿主节点实体(Entity2D/Entity3D)的**补充组件**。
##
## 挂到 Entity2D/Entity3D 下(或其子节点), 自动补充宿主实体的 ECS 组件/字段;
## 宿主实体在 _ready 时沿父节点链自动查找, 也可手动 host_entity 指定。
## 无宿主时纯 OOP 挂载(Node), ecs 桥接不可用, 零开销。

## 宿主节点实体(Entity2D/Entity3D)。_ready 自动从父节点链查找, 或手动设置。
var host_entity: Node = null


func _ready() -> void:
	if host_entity == null:
		host_entity = _find_host()


func _find_host() -> Node:
	var p := get_parent()
	while p != null:
		if p is Entity2D or p is Entity3D:
			return p
		p = p.get_parent()
	return null


## 当前绑定的 ECSLink(宿主实体的); 无宿主返回 null。
func _link() -> ECSLink:
	if host_entity is Entity2D:
		return (host_entity as Entity2D).ecs
	if host_entity is Entity3D:
		return (host_entity as Entity3D).ecs
	return null


## 给宿主实体附加 ECS 数据组件(需挂到 Entity2D/Entity3D 下)
func add_component(comp: Script, values: Dictionary = {}) -> bool:
	var l := _link()
	return l.add_component(comp, values) if l != null else false


func has_component(comp) -> bool:
	var l := _link()
	return l.has_component(comp) if l != null else false


func get_field(comp, field: StringName):
	var l := _link()
	return l.get_field(comp, field) if l != null else null


func set_field(comp, field: StringName, value) -> void:
	var l := _link()
	if l != null:
		l.set_field(comp, field, value)


func is_bound() -> bool:
	var l := _link()
	return l.is_bound() if l != null else false
