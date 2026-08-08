class_name ECSSystemContext
extends RefCounted

## 系统执行上下文 —— 系统内部访问世界数据的唯一通道。
## 推荐统一走 for_each 查询链(C++ batch 执行); 底层列直连见 ECSWorld.get_column/set_column。

var world: ECSWorld
var _pending: Array = []   # 本系统创建的查询(系统 _run 结束后自动执行未显式 execute 的)


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

## 统一查询链入口(与 ECSQuery 同一套遍历→条件→动作构建器)。
## 声明式写法: 链尾无需 .execute() —— 系统 _run 结束后框架自动执行未执行的查询。
## 需要立即结果时仍可显式 .execute()(返回处理实体数)。
func for_each(anchor, must: Array = [], without: Array = []) -> ECSQuery:
	var q = load("res://addons/DEVFramework/ECS/ECSQuery.gd").new()
	q._init_rule(world, anchor, must, without)
	_pending.append(q)
	return q

## 系统 _run 结束后由 ECSWorld 调用: 自动执行本系统未显式 execute 的查询。
func _auto_execute() -> void:
	if _pending.is_empty():
		return
	for q in _pending:
		if q != null and not q._executed:
			q.execute()
	_pending.clear()
