class_name NumHotNativeSystem
extends ECSSystem

## 纯数值热点(原生API层) —— 与 NumHotSystem 相同逻辑, 用 batch 批量运算。
## 回血 + 3 次伤害结算全走原生 batch(单次调用处理全部, C++ 循环)。

func required_components() -> Array[Script]:
	return [BattleCell]

func _run(ctx: ECSSystemContext, _delta: float) -> void:
	var w := ctx.world
	# 回血: hp < 100 的 +2.5 (与伤害平衡, 保持随机分布)
	w.batch_add_value_if(BattleCell, [], BattleCell, &"hp", 2.5,
		[{"comp": BattleCell, "field": &"hp", "op": ECSWorld.CondOp.LESS_THAN, "value": 100.0}])
	# 3 次伤害结算
	w.batch_add_value_if(BattleCell, [], BattleCell, &"hp", -1.0,
		[{"comp": BattleCell, "field": &"hp", "op": ECSWorld.CondOp.GREATER_THAN, "value": 0.0}])
	w.batch_add_value_if(BattleCell, [], BattleCell, &"hp", -1.0,
		[{"comp": BattleCell, "field": &"hp", "op": ECSWorld.CondOp.GREATER_THAN, "value": 0.0}])
	w.batch_add_value_if(BattleCell, [], BattleCell, &"hp", -0.5,
		[{"comp": BattleCell, "field": &"hp", "op": ECSWorld.CondOp.GREATER_THAN, "value": 0.0}])
