class_name NumHotRule
extends ECSSystem

## 纯数值热点(声明式写法) —— 与 NumHotSystem 完全相同的逻辑。
##
## 回血: hp = min(max_hp, hp + 1.5)
## 伤害: hp 受 3 次结算(用 batch 条件减法)

func required_components() -> Array[Script]:
	return [BattleCell]

func _run(ctx: ECSSystemContext, _delta: float) -> void:
	# 回血: hp < 100 的 +2.5 (与伤害平衡, 保持随机分布)
	ctx.for_each(BattleCell).where(&"hp").less_than(100.0).add(&"hp", 2.5).execute()
	# 3 次伤害结算(条件: hp > 0 的扣)
	ctx.for_each(BattleCell).where(&"hp").greater_than(0.0).add(&"hp", -1.0).execute()
	ctx.for_each(BattleCell).where(&"hp").greater_than(0.0).add(&"hp", -1.0).execute()
	ctx.for_each(BattleCell).where(&"hp").greater_than(0.0).add(&"hp", -0.5).execute()
