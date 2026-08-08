class_name BattleSizeSystem
extends ECSSystem

## 大小更新 —— 直接用规则层列间运算(C++ batch 执行, 无 GDScript 循环)。
## size = 8 + hp * 0.08 → set_from(目标=size, 源=hp, factor=0.08, addend=8)

func required_components() -> Array[Script]:
	return [BattleCell]

func _run(ctx: ECSSystemContext, _delta: float) -> void:
	ctx.for_each(BattleCell).set_from(&"size", BattleCell, &"hp", 0.08, 8.0).execute()
