class_name OrderSystemC
extends ECSSystem

## 依赖图测试: 必须在 B 之后执行

static var exec_order: Array = []

func _run(_ctx: ECSSystemContext, _delta: float) -> void:
	exec_order.append("C")
