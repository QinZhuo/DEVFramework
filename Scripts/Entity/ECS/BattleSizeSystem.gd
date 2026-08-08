class_name BattleSizeSystem
extends ECSSystem

## 手写脚本层: 大小更新 —— 与 ECSRule 统一查询链 + Callback 执行。
## size = base + hp * size_per_hp (列间依赖, 用 Callback)

func required_components() -> Array[Script]:
	return [BattleCell]

func _run(ctx: ECSSystemContext, _delta: float) -> void:
	ctx.for_each(BattleCell).each(_size_cb, [BattleCell]).execute()


func _size_cb(rows: PackedInt32Array, _comp_rows: Dictionary, w: ECSWorld) -> void:
	var size_col: PackedFloat32Array = w.get_column(BattleCell, &"size")
	var hp_col: PackedFloat32Array = w.get_column(BattleCell, &"hp")
	for r in rows:
		size_col[r] = 8.0 + hp_col[r] * 0.08
	w.set_column(BattleCell, &"size", size_col)
