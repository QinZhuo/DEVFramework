class_name HealRule
extends ECSRule

## 声明规则测试: 给 hp < 50 的实体回血 10 点

func required_components() -> Array[Script]:
	return [HealthComponent]

func _define(ctx: ECSRuleContext) -> void:
	ctx.for_each(HealthComponent).where(&"hp").less_than(50).add(&"hp", 10)
