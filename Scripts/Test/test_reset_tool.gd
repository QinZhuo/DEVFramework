extends TestCase

## ResetTool 的契约：切场景后框架的静态状态必须回到初始。
## 这些状态原本寄生在 Tool 的 static var 上，不清就会被带到下一局。

var _panels: Array[Node] = []


func cleanup() -> void:
	for p in _panels:
		if is_instance_valid(p):
			p.free()
	_panels.clear()
	ResetTool.all()


func test_reset_clears_ui_stack() -> void:
	var panel := UIPanel.new()
	_panels.append(panel)
	UITool.register(panel)
	assert_eq(UITool.get_stack_size(), 1, "注册后栈里应有 1 个面板")

	ResetTool.all()
	assert_eq(UITool.get_stack_size(), 0, "ResetTool 应清空 UI 栈")
	assert_true(UITool.get_top() == null, "栈顶应为空")


func test_reset_restores_time() -> void:
	TimeTool.set_base_speed(2.0)
	assert_true(TimeTool.get_current_scale() > 1.0, "先制造一个非 1x 状态")

	ResetTool.all()
	assert_true(is_equal_approx(Engine.time_scale, 1.0), "Engine.time_scale 应回到 1x")
	assert_true(is_equal_approx(TimeTool.get_current_scale(), 1.0), "TimeTool 应回到 1x")


func test_reset_is_repeatable() -> void:
	ResetTool.all()
	ResetTool.all()
	assert_eq(UITool.get_stack_size(), 0, "重复复位不应产生副作用")
	assert_true(is_equal_approx(TimeTool.get_current_scale(), 1.0))
