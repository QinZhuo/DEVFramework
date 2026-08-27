class_name PTSysDepA
extends ECSSystem

## 依赖测试: 无组件, 依赖链起点

static var order: Array = []

func can_run_parallel() -> bool:
	return true

func _run(_ctx: ECSSystemContext, _delta: float) -> void:
	order.append("A")
