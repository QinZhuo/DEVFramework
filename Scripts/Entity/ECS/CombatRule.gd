class_name CombatRule
extends ECSRule

## 战斗规则测试: 多条件 + 多动作
##   - hp > 80 的实体: 扣 30 血(攻击)
##   - hp <= 0 的实体: 设为 1(保底)

func required_components() -> Array[Script]:
	return [HealthComponent]

func _define(ctx: ECSRuleContext) -> void:
	# 高血量被打: hp > 80 的 -30
	ctx.for_each(HealthComponent).where(&"hp").greater_than(80).add(&"hp", -30)
	# 保底: hp <= 0 的设为 1
	ctx.for_each(HealthComponent).where(&"hp").less_or_equal(0).set_value(&"hp", 1)
