class_name BattleHealSystem
extends ECSSystem

## 战斗回血系统(手写脚本层) —— GDScript 循环回血。
## 与 BattleRecoverRule(声明规则层)/BattleNativeHealSystem(原生API层)
## 做完全一样的事: 每秒回 2 点, hp < 100 才回。
## 保证三路逻辑一致, 只体现"实现方式"差异。

func required_components() -> Array[Script]:
	return [BattleCell]

func _run(ctx: ECSSystemContext, _delta: float) -> void:
	var w := ctx.world
	var rows: PackedInt32Array = w.query_rows(BattleCell, [], [])
	var hp_col: PackedFloat32Array = w.get_column(BattleCell, &"hp")
	# GDScript 循环(手写脚本层): hp < 100 的 +2
	for e in rows:
		if hp_col[e] < 100.0:
			hp_col[e] += 2.0
	w.set_column(BattleCell, &"hp", hp_col)
