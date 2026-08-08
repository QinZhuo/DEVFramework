class_name PTSysC
extends ECSSystem

## 并行测试系统 C: 只访问 PTCompC

static var frame := 0

func required_components() -> Array[Script]:
	return [PTCompC]

func can_run_parallel() -> bool:
	return true

func _run(ctx: ECSSystemContext, _delta: float) -> void:
	frame += 1
	if frame <= 8:
		print("[PTSysC] frame=%d thread=%d" % [frame, OS.get_thread_caller_id()])
	var rows: PackedInt32Array = ctx.rows(PTCompC)
	if rows.is_empty():
		return
	var col: PackedInt32Array = ctx.column(PTCompC, &"x")
	ctx.write(PTCompC, &"x", col)
