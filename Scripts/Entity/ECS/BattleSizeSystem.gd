class_name BattleSizeSystem
extends ECSSystem

## 手写脚本层: 大小更新 —— GDScript 循环。
## size = base + hp * size_per_hp

func required_components() -> Array[Script]:
	return [BattleCell]

func _run(ctx: ECSSystemContext, _delta: float) -> void:
	var w := ctx.world
	var rows: PackedInt32Array = w.query_rows(BattleCell, [], [])
	var size_col: PackedFloat32Array = w.get_column(BattleCell, &"size")
	var hp_col: PackedFloat32Array = w.get_column(BattleCell, &"hp")
	# GDScript 循环(手写脚本层)
	for e in rows:
		size_col[e] = 8.0 + hp_col[e] * 0.08
	w.set_column(BattleCell, &"size", size_col)
