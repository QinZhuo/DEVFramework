class_name BenchmarkSystem
extends ECSSystem

## 基准系统: 模拟战斗数值计算
## 每实体: hp 增加/回复, 位置移动, 属性校验

func required_components() -> Array[Script]:
	return [HealthComponent, MoveComponent]

func _run(ctx: ECSSystemContext, delta: float) -> void:
	var rows: PackedInt32Array = ctx.rows(HealthComponent, [MoveComponent])
	if rows.is_empty():
		return
	var hp: PackedInt32Array = ctx.column(HealthComponent, &"hp")
	var max_hp: PackedInt32Array = ctx.column(HealthComponent, &"max_hp")
	var x: PackedFloat32Array = ctx.column(MoveComponent, &"x")
	var y: PackedFloat32Array = ctx.column(MoveComponent, &"y")
	var vx: PackedFloat32Array = ctx.column(MoveComponent, &"vx")
	var vy: PackedFloat32Array = ctx.column(MoveComponent, &"vy")
	for r in rows:
		if hp[r] < max_hp[r]:
			hp[r] = mini(hp[r] + 1, max_hp[r])
		x[r] += vx[r] * delta
		y[r] += vy[r] * delta
	ctx.write(HealthComponent, &"hp", hp)
	ctx.write(MoveComponent, &"x", x)
	ctx.write(MoveComponent, &"y", y)
