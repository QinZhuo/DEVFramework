class_name PTSysA
extends ECSSystem

## 并行测试系统 A: 只访问 PTCompA

static var frame := 0

func required_components() -> Array[Script]:
	return [PTCompA]

func can_run_parallel() -> bool:
	return true

func _run(ctx: ECSSystemContext, _delta: float) -> void:
	frame += 1
	if frame <= 8:
		print("[PTSysA] frame=%d thread=%d" % [frame, OS.get_thread_caller_id()])
	ctx.for_each(PTCompA).each(func(rows: PackedInt32Array, data: Dictionary):
		var col: PackedInt32Array = data["PTCompA"]["x"]
		for r in rows:
			col[r] += 0
	, {PTCompA: [&"x"]}).execute()
