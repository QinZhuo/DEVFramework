class_name PTSysDepB
extends ECSSystem

## 依赖测试: 必须在 PTSysDepA 之后执行

func can_run_parallel() -> bool:
	return true

func _run(_ctx: ECSSystemContext, _delta: float) -> void:
	PTSysDepA.order.append("B")
