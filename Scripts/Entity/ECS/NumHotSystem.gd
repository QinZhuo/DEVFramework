class_name NumHotSystem
extends ECSSystem

## 纯数值热点(手写脚本层) —— 大规模数值变换用 GDScript 循环。
##
## 模拟真实战斗数值结算: 每个实体做多次数值操作。
##   - 回血: hp = min(max_hp, hp + regen)
##   - 减伤: hp 受 3 次伤害结算
##   - 攻击力: atk = base * (1 + buff%) * 状态修正
## 与声明规则层/原生API层做完全相同的逻辑, 对比性能。

func required_components() -> Array[Script]:
	return [BattleCell]

func _run(ctx: ECSSystemContext, _delta: float) -> void:
	var w := ctx.world
	var rows: PackedInt32Array = w.query_rows(BattleCell, [], [])
	if rows.is_empty():
		return
	var hp_col: PackedFloat32Array = w.get_column(BattleCell, &"hp")
	var max_col: PackedFloat32Array = w.get_column(BattleCell, &"max_hp")
	var dmg_col: PackedFloat32Array = w.get_column(BattleCell, &"dmg")
	# GDScript 循环: 每实体多次数值运算(手写脚本层)
	for e in rows:
		# 回血(与伤害平衡, 保持血量随机分布以显示状态差异)
		var h: float = hp_col[e]
		var m: float = max_col[e]
		if h < m:
			h = mini(h + 2.5, m)
		# 3 次伤害结算: atk=5 → 2.5/次, 与回血持平
		var atk := dmg_col[e]
		h -= atk * 0.2
		h -= atk * 0.2
		h -= atk * 0.1
		hp_col[e] = maxf(h, 0.0)
	w.set_column(BattleCell, &"hp", hp_col)
