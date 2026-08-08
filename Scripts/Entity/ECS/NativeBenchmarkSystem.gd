class_name NativeBenchmarkSystem
extends ECSSystem

## 原生API层基准系统: 全部走 C++ 原生批量运算, GDScript 只做一次调用。

func required_components() -> Array[Script]:
	return [HealthComponent, MoveComponent]

func _run(ctx: ECSSystemContext, delta: float) -> void:
	var w := ctx.world
	# op: 0=ADD 1=MUL_ADD 2=SET 3=CLAMP (ECSCore.BatchOp 原生枚举, GDScript 侧用字面量)
	# 1) hp 回复: hp = min(max_hp, hp + 1) => 先 +1 再 clamp
	w.batch_apply(HealthComponent, [MoveComponent], HealthComponent, &"hp", 0, 0.0, 1.0)
	w.batch_clamp(HealthComponent, [MoveComponent], HealthComponent, &"hp",
		HealthComponent, &"max_hp", HealthComponent, &"max_hp")
	# 2) 位置积分: x += vx * delta, y += vy * delta
	w.batch_apply(MoveComponent, [HealthComponent], MoveComponent, &"x", 1, 1.0, delta)
	w.batch_apply(MoveComponent, [HealthComponent], MoveComponent, &"y", 1, 1.0, delta)
