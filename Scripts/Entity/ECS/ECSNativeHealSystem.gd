class_name ECSNativeHealSystem
extends ECSSystem

## 原生API层: 治疗系统 —— 纯 C++ 批量运算, 无 GDScript 循环。
## 与 HealSystem(手写脚本层)逻辑完全对称: hp 每秒回复 5, 封顶 max_hp。
## 区别: 全部在 C++ 内循环完成, GDScript 只发起 2 次调用。

func required_components() -> Array[Script]:
	return [HealthComponent]

func _run(ctx: ECSSystemContext, delta: float) -> void:
	var w := ctx.world
	# op=0 (ADD): hp += 5*delta*60 (每秒 5)
	w.batch_apply(HealthComponent, [], HealthComponent, &"hp", 0, 0.0, 5.0 * delta * 60.0)
	# clamp: hp = min(hp, max_hp)
	w.batch_clamp(HealthComponent, [], HealthComponent, &"hp",
		HealthComponent, &"max_hp", HealthComponent, &"max_hp")
