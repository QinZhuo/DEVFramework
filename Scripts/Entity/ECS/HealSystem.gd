class_name HealSystem
extends ECSSystem

## 测试系统: 每秒回复 5 点 hp, 上限 max_hp

static var exec_order: Array = []

func required_components() -> Array[Script]:
	return [HealthComponent]

## 声明写入的组件(依赖图自动推断用: 写 hp 的系统需在读数系统之前)
func write_components() -> Array[Script]:
	return [HealthComponent]

func _run(ctx: ECSSystemContext, delta: float) -> void:
	exec_order.append("Heal")
	ctx.for_each(HealthComponent).each(func(rows: PackedInt32Array, data: Dictionary):
		var hp: PackedInt32Array = data["HealthComponent"]["hp"]
		var max_hp: PackedInt32Array = data["HealthComponent"]["max_hp"]
		var heal := int(5.0 * delta * 60.0)
		for r in rows:
			if hp[r] < max_hp[r]:
				hp[r] = mini(hp[r] + heal, max_hp[r])
	, {HealthComponent: [&"hp", &"max_hp"]}).execute()
