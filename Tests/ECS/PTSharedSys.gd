class_name PTSharedSys
extends ECSSystem

## 并行测试系统: 访问 PTCompA(与 PTSysA 冲突 → 必须串行其后)

static var frame := 0

func required_components() -> Array[Script]:
	return [PTCompA]

func can_run_parallel() -> bool:
	return true

func _run(ctx: ECSSystemContext, _delta: float) -> void:
	frame += 1
	if frame <= 8:
		print("[PTShared] frame=%d thread=%d" % [frame, OS.get_thread_caller_id()])
	var rows: PackedInt32Array = ctx.rows(PTCompA)
	if rows.is_empty():
		return
	var col: PackedInt32Array = ctx.column(PTCompA, &"x")
	for r in rows:
		col[r] += 1
	ctx.write(PTCompA, &"x", col)
