class_name PTSysB
extends ECSSystem

## 并行测试系统 B: 只访问 PTCompB

static var frame := 0

func required_components() -> Array[Script]:
	return [PTCompB]

func can_run_parallel() -> bool:
	return true

func _run(ctx: ECSSystemContext, _delta: float) -> void:
	frame += 1
	if frame <= 8:
		print("[PTSysB] frame=%d thread=%d" % [frame, OS.get_thread_caller_id()])
	var rows: PackedInt32Array = ctx.rows(PTCompB)
	if rows.is_empty():
		return
	var col: PackedInt32Array = ctx.column(PTCompB, &"x")
	ctx.write(PTCompB, &"x", col)
