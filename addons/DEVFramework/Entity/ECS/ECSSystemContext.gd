class_name ECSSystemContext
extends RefCounted

## 系统执行上下文 —— 系统内部访问世界数据的唯一通道。
## 高频路径全走"整列批量"模式, 避免逐实体跨语言调用。

var world: ECSWorld

func _init(p_world: ECSWorld) -> void:
	world = p_world

## 匹配实体行号列表(anchor 组件的 dense 行号, 可直接索引该组件列)
func rows(anchor, must: Array = [], without: Array = []) -> PackedInt32Array:
	return world.query_rows(anchor, must, without)

## 取某组件某字段的整列(按 anchor 组件的行号索引, 本地只读/修改)
func column(component, field: StringName):
	return world.get_column(component, field)

## 整列写回(修改后必须调用)
func write(component, field: StringName, values) -> void:
	world.set_column(component, field, values)

## 单实体读写(低频路径, 避免在循环内使用)
func get_field(entity: int, component, field: StringName):
	return world.get_field(entity, component, field)

func set_field(entity: int, component, field: StringName, value) -> void:
	world.set_field(entity, component, field, value)

## 投递事件(帧末统一派发)
func emit(type: StringName, payload = null) -> void:
	world.emit_event(type, payload)

## 统一查询链入口(与 ECSRule 同一套遍历→条件→动作构建器)。
## 手写系统也可用: for_each(Comp).where(...).add(...) 走 C++ batch(最快),
## 或 .each(callback) 用 GDScript 自定义逻辑(最灵活)。
## 注意: 与 ECSRule(由 _execute_all 自动执行)不同, 系统内构建的查询必须链尾 .execute():
##   ctx.for_each(Comp).where(...).add(...).execute()
##   ctx.for_each(Comp).each(cb, [Comp]).execute()
## 见 ECSRuleQuery 文档。
func for_each(anchor, must: Array = [], without: Array = []) -> ECSRuleQuery:
	var q = load("res://addons/DEVFramework/Entity/ECS/ECSRuleQuery.gd").new()
	q._init_rule(world, anchor, must, without)
	return q
