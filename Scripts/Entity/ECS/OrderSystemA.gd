class_name OrderSystemA
extends ECSSystem

## 依赖图测试: 无依赖, 记录执行顺序

static var exec_order: Array = []

func _run(_ctx: ECSSystemContext, _delta: float) -> void:
	exec_order.append("A")
