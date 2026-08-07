class_name ECSScriptMoveSystem
extends ECSSystem

## 脚本(Tier2)移动系统 —— GDScript 列循环。
## 与 ECSMoveSystem(Tier0)逻辑完全对称: pos += vel * delta。
## 区别: 逐实体在 GDScript 中循环访问列数组。

func required_components() -> Array[Script]:
	return [ECSDemoMoveComponent]

func _run(ctx: ECSSystemContext, delta: float) -> void:
	var rows: PackedInt32Array = ctx.rows(ECSDemoMoveComponent)
	if rows.is_empty():
		return
	var pos: PackedVector2Array = ctx.column(ECSDemoMoveComponent, &"pos")
	var vel: PackedVector2Array = ctx.column(ECSDemoMoveComponent, &"vel")
	for r in rows:
		pos[r] += vel[r] * delta
	ctx.write(ECSDemoMoveComponent, &"pos", pos)
