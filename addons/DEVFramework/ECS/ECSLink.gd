class_name ECSLink extends RefCounted

## ECS 桥接对象 —— 让普通对象(Node/RefCounted)把数据放进 ECS。
##
## 隐式启用: 调用 add_component/get_field/set_field 等时自动创建并绑定一个 ECS 实体,
## 无需任何布尔开关。不使用 ecs.* API 则保持纯 OOP, 零开销。
## 数据单一源 = ECS 列; 持有方(Node 组件 / 实体对象)只做门面。
##
## 用法(在 Entity / Component 内建, 子类直接用):
##   ecs.world = my_world                       # 绑定世界(由使用方设置)
##   ecs.add_component(ECSAttribute, {"atk": 10})   # 数据进 ECS 列
##   ecs.set_field(ECSAttribute, &"atk", 20)    # 读写 ECS
##   ecs.destroy()                              # 销毁实体

var world: ECSWorld
var entity_id: int = -1


## 懒创建 ECS 实体(首次使用时绑定), 返回实体 ID。
func ensure_entity() -> int:
	if entity_id < 0 and world != null:
		entity_id = world.create_entity()
	return entity_id


## 是否已绑定一个活实体。
func is_bound() -> bool:
	return entity_id >= 0 and world != null and world.is_alive(entity_id)


## 给实体附加 ECS 数据组件(数据只在 ECS 列)。
func add_component(comp: Script, values: Dictionary = {}) -> bool:
	if world == null:
		push_warning("ECSLink: 未设置 world, 无法附加组件。请先 ecs.world = ...")
		return false
	return world.add_component(ensure_entity(), comp, values)


func has_component(comp) -> bool:
	return entity_id >= 0 and world != null and world.has_component(entity_id, comp)


## 读 ECS 字段(实体不存在返回 null, 不创建)。
func get_field(comp, field: StringName):
	if entity_id < 0:
		return null
	return world.get_field(entity_id, comp, field)


## 写 ECS 字段(懒创建: 使用到时才创建实体, 并自动附加该组件)。
func set_field(comp, field: StringName, value) -> void:
	if world == null:
		push_warning("ECSLink: 未设置 world, 无法写入字段。请先 ecs.world = ...")
		return
	var e := ensure_entity()
	if not world.has_component(e, comp):
		world.add_component(e, comp)
	world.set_field(e, comp, field, value)


## 销毁绑定的 ECS 实体(生命周期清理)。
func destroy() -> void:
	if entity_id >= 0 and world != null and world.is_alive(entity_id):
		world.destroy_entity(entity_id)
	entity_id = -1
