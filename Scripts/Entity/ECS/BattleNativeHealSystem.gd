class_name BattleNativeHealSystem
extends ECSSystem

## 战斗回血系统(原生API层) —— 用 batch 批量回血。
## 与 BattleRecoverRule(声明规则层) 做同样的事, 展示原生API层写法。

func required_components() -> Array[Script]:
	return [BattleCell]

func _run(ctx: ECSSystemContext, _delta: float) -> void:
	var w := ctx.world
	# 每秒回 2 点: hp < 100 的 +2 (batch 原生批量)
	w.batch_apply_where(BattleCell, [], BattleCell, &"hp", ECSWorld.BatchOp.ADD_VALUE, 0.0, 2.0,
		[{"comp": BattleCell, "field": &"hp", "op": ECSWorld.CondOp.LESS_THAN, "value": 100.0}])
