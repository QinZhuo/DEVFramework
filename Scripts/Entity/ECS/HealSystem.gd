class_name HealSystem
extends ECSSystem

## 测试系统: 每秒回复 5 点 hp, 上限 max_hp

func required_components() -> Array[Script]:
	return [HealthComponent]

func _run(ctx: ECSSystemContext, delta: float) -> void:
	var rows: PackedInt32Array = ctx.rows(HealthComponent)
	if rows.is_empty():
		return
	var hp: PackedInt32Array = ctx.column(HealthComponent, &"hp")
	var max_hp: PackedInt32Array = ctx.column(HealthComponent, &"max_hp")
	var heal := int(5.0 * delta * 60.0)
	for r in rows:
		if hp[r] < max_hp[r]:
			hp[r] = mini(hp[r] + heal, max_hp[r])
	ctx.write(HealthComponent, &"hp", hp)
