@abstract class_name Entity extends RefCounted

## 运行时实体基类 —— 也是 **ECS 桥接的重点**。
##
## 理想用法: 只用 Entity(及其子类) 就能把数据放进 ECS, 无需接触裸 ECS API:
##   var e := Entity.new()                  # 或 Buff/Modifier 等子类
##   e.ecs.world = world                    # 绑定世界(懒创建 ECS 实体)
##   e.add_component(HealthComponent, {"hp": 100})   # 数据进 ECS 列
##   e.set_field(HealthComponent, &"hp", 80)         # 读写 ECS
##   e.destroy()                            # 销毁
## 数据只在 ECS(SoA 列), Entity 对象只是门面; 不调用 ECS API 则纯 OOP, 零开销。
## Component(Node) 仅作为"表现/交互补充"时使用(见 Component 文档)。

signal entity_changed()

## ECS 桥接(数据可放 ECS 列, 懒创建 —— 只有用到 ecs 时才实例化)
var _ecs: ECSLink = null
var ecs: ECSLink:
	get:
		if _ecs == null:
			_ecs = ECSLink.new()
		return _ecs
	set(v):
		_ecs = v


func _init(init_def: Def = null):
	if init_def:
		if "def" in self:
			set("def", init_def)


## —— ECS 实体门面(用户直接调用) ——

## 给本实体附加 ECS 数据组件(懒创建 ECS 实体)
func add_component(comp: Script, values: Dictionary = {}) -> bool:
	return ecs.add_component(comp, values)


func has_component(comp) -> bool:
	return ecs.has_component(comp)


## 读 ECS 字段
func get_field(comp, field: StringName):
	return ecs.get_field(comp, field)


## 写 ECS 字段
func set_field(comp, field: StringName, value) -> void:
	ecs.set_field(comp, field, value)


## 是否已绑定活 ECS 实体
func is_bound() -> bool:
	return ecs.is_bound()


## 销毁绑定的 ECS 实体
func destroy() -> void:
	ecs.destroy()


func _to_string():
	if "def" in self:
		return str(get("def"))
	return str(hash(self))


## —— 传统属性路由(路线A): 直接读写 schema 字段自动进 ECS ——
## 仅当 ecs 已初始化(world 已设置)且字段属于已注册组件时才接管;
## 否则走默认逻辑, 保持懒加载(不用 ECS 则零开销、纯 OOP)。

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


func get_desc(data):
	if "def" in self:
		return get("def").get_desc(data)
	return _to_string()
