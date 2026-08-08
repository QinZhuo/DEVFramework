class_name ECSSystemContext
extends RefCounted

## 系统执行上下文 —— 系统内部访问世界数据的唯一通道。
## 推荐统一走 for_each 查询链(C++ batch 执行); 底层列直连见 ECSWorld.get_column/set_column。

var world: ECSWorld

func _init(p_world: ECSWorld) -> void:
	world = p_world

## 单实体读写(低频路径, 避免在循环内使用)
func get_field(entity: int, component, field: StringName):
	return world.get_field(entity, component, field)

func set_field(entity: int, component, field: StringName, value) -> void:
	world.set_field(entity, component, field, value)

## 投递事件(帧末统一派发, 同 world.emit_event)
func emit_event(type: StringName, payload = null) -> void:
	world.emit_event(type, payload)

## 统一查询链入口(与 查询链 同一套遍历→条件→动作构建器)。
## 手写系统也可用: for_each(Comp).where(...).add(...) 走 C++ batch(最快),
## 或 .process(callback) 用 GDScript 自定义逻辑(最灵活)。
## 注意: 与 查询链(由 _execute_all 自动执行)不同, 系统内构建的查询必须链尾 .execute():
##   ctx.for_each(Comp).where(...).add(...).execute()
##   ctx.for_each(Comp).process(cb, [Comp]).execute()
## 见 ECSQuery 文档。
func for_each(anchor, must: Array = [], without: Array = []) -> ECSQuery:
	var q = load("res://addons/DEVFramework/ECS/ECSQuery.gd").new()
	q._init_rule(world, anchor, must, without)
	return q
