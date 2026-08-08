class_name BattleRecoverRule
extends ECSRule

## 战斗回血规则(声明规则层) —— 每秒回复少量血。
## 用于展示: 复杂战斗中的数值变化用声明规则声明式表达。

func required_components() -> Array[Script]:
	return [BattleCell]

func _define(ctx: ECSRuleContext) -> void:
	# 每秒回 2 点: hp < 100 的 +2 (链式, 一行写法)
	ctx.for_each(BattleCell).where(&"hp").less_than(100.0).add(&"hp", 2.0)
