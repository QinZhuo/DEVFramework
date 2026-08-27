class_name PTSysDepC
extends ECSSystem

## 依赖测试: 必须在 PTSysDepB 之后执行

func can_run_parallel() -> bool:
	return true

func _run(_ctx: ECSSystemContext, _delta: float) -> void:
	PTSysDepA.order.append("C")
