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
	ctx.for_each(PTCompB).each(func(rows: PackedInt32Array, data: Dictionary):
		var col: PackedInt32Array = data["PTCompB"]["x"]
		for r in rows:
			col[r] += 0
	, {PTCompB: [&"x"]}).execute()
