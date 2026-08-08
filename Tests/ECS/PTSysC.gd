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
	ctx.for_each(PTCompC).each(func(rows: PackedInt32Array, data: Dictionary):
		var col: PackedInt32Array = data["PTCompC"]["x"]
		for r in rows:
			col[r] += 0
	, {PTCompC: [&"x"]}).execute()
