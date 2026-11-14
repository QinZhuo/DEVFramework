extends TestCase

## ModifierValue 的聚合公式：(base + ΣVALUE) × ΠPERCENT，内部浮点、对外取整。
## 这是全项目数值的底座 —— 符号或阶段搞错，所有属性都会静默偏移，没有任何报错。

const SRC_A := "装备A"
const SRC_B := "BuffB"


func _mv(base: int) -> ModifierValue:
	var v := ModifierValue.new()
	v.base_value = base
	return v


func test_base_only() -> void:
	assert_eq(_mv(100).value, 100, "没有修饰器时 value = base")


func test_value_then_percent_is_staged() -> void:
	var v := _mv(100)
	v.add_modifier(Modifier.new(SRC_A, 20, Modifier.Mode.VALUE))
	v.add_modifier(Modifier.new(SRC_A, 150, Modifier.Mode.PERCENT))
	assert_eq(v.value, 180, "先加固定值再乘百分比：(100+20)*1.5，不能是 100*1.5+20")


func test_percent_below_hundred() -> void:
	var v := _mv(100)
	v.add_modifier(Modifier.new(SRC_A, 50, Modifier.Mode.PERCENT))
	assert_eq(v.value, 50, "50% 应是减半")


func test_percents_multiply() -> void:
	var v := _mv(100)
	v.add_modifier(Modifier.new(SRC_A, 150, Modifier.Mode.PERCENT))
	v.add_modifier(Modifier.new(SRC_B, 200, Modifier.Mode.PERCENT))
	assert_eq(v.value, 300, "多个百分比连乘(1.5*2.0)，不是相加")


func test_value_modifiers_sum() -> void:
	var v := _mv(10)
	v.add_modifier(Modifier.new(SRC_A, 5))
	v.add_modifier(Modifier.new(SRC_B, 7))
	assert_eq(v.value, 22, "多个固定值累加")


func test_order_independent() -> void:
	var a := _mv(100)
	a.add_modifier(Modifier.new(SRC_A, 20))
	a.add_modifier(Modifier.new(SRC_A, 150, Modifier.Mode.PERCENT))
	var b := _mv(100)
	b.add_modifier(Modifier.new(SRC_A, 150, Modifier.Mode.PERCENT))
	b.add_modifier(Modifier.new(SRC_A, 20))
	assert_eq(a.value, b.value, "分阶段聚合应与加入顺序无关")


func test_remove_modifiers_by_source() -> void:
	var v := _mv(100)
	v.add_modifier(Modifier.new(SRC_A, 20))
	v.add_modifier(Modifier.new(SRC_B, 30))
	assert_eq(v.value, 150)

	v.remove_modifiers(SRC_A)
	assert_eq(v.value, 130, "只移除该来源的修饰器")

	v.clear_modifiers()
	assert_eq(v.value, 100, "全部清空后回到 base")


func test_value_changed_carries_modifier() -> void:
	var v := _mv(100)
	var seen: Array = []
	v.value_changed.connect(func(m): seen.append(m))
	var mod := Modifier.new(SRC_A, 10)
	v.add_modifier(mod)
	assert_eq(seen.size(), 1, "值变化应广播一次")
	assert_true(seen[0] == mod, "广播应带上引发变化的修饰器")


func test_base_change_recomputes() -> void:
	var v := _mv(100)
	v.add_modifier(Modifier.new(SRC_A, 150, Modifier.Mode.PERCENT))
	v.base_value = 200
	assert_eq(v.value, 300, "改 base 必须整链重算")


func test_reset_clears_everything() -> void:
	var v := _mv(100)
	v.add_modifier(Modifier.new(SRC_A, 20))
	v.reset()
	assert_eq(v.value, 0, "reset 后 base 与修饰器都应清空")
	assert_eq(v.base_value, 0)


## 允许范围极值不应溢出成负数（MathTool.clamp_signed 的兜底）。
func test_extreme_percent_does_not_overflow() -> void:
	var v := _mv(1000000)
	v.add_modifier(Modifier.new(SRC_A, 1000000, Modifier.Mode.PERCENT))
	assert_true(v.value >= 0, "钳位后不应变成负数")
