extends TestCase

## TimeTool 的契约：最终 time_scale = base × ∏PERCENT，且物理频率必须跟着"档位"走。
## 时间缩放错了不会报错 —— 它只会让同样的输入跑出不同结果（物理采样粒度变了）。


func cleanup() -> void:
	TimeTool.reset()


func test_base_speed_applies() -> void:
	TimeTool.reset()
	TimeTool.set_base_speed(2.0)
	assert_true(is_equal_approx(TimeTool.get_current_scale(), 2.0), "基础速度应直接生效")
	assert_true(is_equal_approx(Engine.time_scale, 2.0), "Engine.time_scale 应同步")


func test_physics_ticks_follow_base_speed() -> void:
	TimeTool.reset()
	var base := TimeTool.base_ticks()
	TimeTool.set_base_speed(2.0)
	assert_eq(Engine.physics_ticks_per_second, base * 2,
			"提速必须同时抬高物理频率，否则每 tick 的 game delta 会变")


func test_modifier_multiplies_base() -> void:
	TimeTool.reset()
	TimeTool.set_base_speed(2.0)
	TimeTool.set_modifier("slow", 0.5)
	assert_true(is_equal_approx(TimeTool.get_current_scale(), 1.0), "2.0 × 50% = 1.0")


func test_same_key_replaces() -> void:
	TimeTool.reset()
	TimeTool.set_modifier("k", 0.5)
	TimeTool.set_modifier("k", 2.0)
	assert_true(is_equal_approx(TimeTool.get_current_scale(), 2.0), "同 key 应替换而不是叠加")


func test_pause_resume() -> void:
	TimeTool.reset()
	TimeTool.pause()
	assert_true(TimeTool.is_paused(), "pause 后应标记为暂停")
	assert_true(is_equal_approx(TimeTool.get_current_scale(), 0.0), "暂停 = 缩放 0")

	TimeTool.resume()
	assert_false(TimeTool.is_paused(), "resume 后应解除暂停")
	assert_true(is_equal_approx(TimeTool.get_current_scale(), 1.0), "恢复后回到 1x")


## reset 是"切场景/回标题"的兜底：暂停、倍速、物理频率都要回到默认。
func test_reset_restores_defaults() -> void:
	TimeTool.set_base_speed(3.0)
	TimeTool.pause()
	TimeTool.reset()
	assert_true(is_equal_approx(Engine.time_scale, 1.0), "Engine.time_scale 应回到 1x")
	assert_true(is_equal_approx(TimeTool.get_base_speed(), 1.0), "基础速度应回到 1x")
	assert_false(TimeTool.is_paused(), "不应残留暂停标记")
	assert_eq(Engine.physics_ticks_per_second, TimeTool.base_ticks(), "物理频率应回到项目设置值")
