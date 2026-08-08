class_name BattleHealSystem
extends ECSSystem

## 战斗回血系统(手写脚本层) —— 直接声明为 ECSRule 查询链(C++ batch 执行)。
## 与 BattleRecoverRule(声明规则层)/BattleNativeHealSystem(原生API层)
## 做完全一样的事: 每秒回 2 点, hp < 100 才回。
## 手写层与规则层共用同一查询链: 这里就是"用脚本写出的规则"。

func required_components() -> Array[Script]:
	return [BattleCell]

func _run(ctx: ECSSystemContext, _delta: float) -> void:
	# 与声明规则层完全相同的查询链 → C++ batch 执行, 无 GDScript 循环
	ctx.for_each(BattleCell).where(&"hp").less_than(100.0).add(&"hp", 2.0).execute()
