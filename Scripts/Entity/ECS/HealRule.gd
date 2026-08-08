class_name HealRule
extends ECSSystem

## 声明规则测试: 给 hp < 50 的实体回血 10 点(声明式写法)

func required_components() -> Array[Script]:
	return [HealthComponent]

func _run(ctx: ECSSystemContext, _delta: float) -> void:
	ctx.for_each(HealthComponent).where(&"hp").less_than(50).add(&"hp", 10).execute()
