extends TestCase

## GOAP 规划器的契约：从目标反向搜索，产出**最小代价、可执行顺序**的行动序列。
## 规划错了不会报错 —— 只会让 AI 一直做无效动作，或在半路卡死。
##
## 断言一律比**对象身份**而不是名字：运行时 new 出来的 Def 没有 resource_path，
## `Def.name` 的 getter 会把内置资源的名字强制取成脚本类名（"GoapActionDef"），
## 按名字断言等于在测一个不受控的值。

func _act(n: String, pre: Dictionary, eff: Dictionary, cost := 1.0) -> GoapActionDef:
	var d := GoapActionDef.new()
	d.name = n
	d.preconditions = pre
	d.effects = eff
	d.cost = cost
	return d


func _state(values: Dictionary) -> GoapWorldState:
	var ws := GoapWorldState.new()
	ws.reset(values)
	return ws


func _defs(plan: Array) -> Array:
	var out := []
	for a in plan:
		out.append(a.def)
	return out


func test_goal_already_satisfied_needs_no_plan() -> void:
	var p := GoapPlanner.new()
	var plan := p.plan(_state({"hungry": false}), {"hungry": false},
			[_act("eat", {}, {"hungry": false})])
	assert_eq(plan.size(), 0, "目标已满足时不应产出任何行动")


func test_single_action_plan() -> void:
	var p := GoapPlanner.new()
	var eat := _act("eat", {}, {"hungry": false})
	var plan := p.plan(_state({"hungry": true}), {"hungry": false}, [eat])
	assert_eq(plan.size(), 1, "一步可达应产出唯一行动")
	assert_true(plan[0].def == eat, "产出的行动应来自传入的那条定义")


## 行动顺序必须是"先满足前提、再达成目标"，不能反过来。
func test_two_step_chain_is_ordered() -> void:
	var p := GoapPlanner.new()
	var walk := _act("walk", {"near_food": true}, {"has_food": true})
	var find := _act("find", {}, {"near_food": true})
	var plan := p.plan(_state({}), {"has_food": true}, [walk, find])
	assert_eq(plan.size(), 2, "两段链应产出两个行动")
	assert_true(plan[0].def == find, "第一个应满足前提")
	assert_true(plan[1].def == walk, "第二个才达成目标")


func test_prefers_lower_cost() -> void:
	var p := GoapPlanner.new()
	var expensive := _act("expensive", {}, {"done": true}, 5.0)
	var cheap := _act("cheap", {}, {"done": true}, 1.0)
	var plan := p.plan(_state({}), {"done": true}, [expensive, cheap])
	assert_eq(plan.size(), 1)
	assert_true(plan[0].def == cheap, "两条路都通时应选代价更低的")


func test_unreachable_goal_yields_empty_plan() -> void:
	var p := GoapPlanner.new()
	var plan := p.plan(_state({}), {"impossible": true},
			[_act("other", {}, {"something": true})])
	assert_eq(plan.size(), 0, "没有任何行动能产出目标时返回空，而不是乱给一条")


func test_max_depth_limits_search() -> void:
	var p := GoapPlanner.new()
	p.max_depth = 1
	var actions := [
		_act("c", {"b": true}, {"goal": true}),
		_act("b", {"a": true}, {"b": true}),
		_act("a", {}, {"a": true}),
	]
	var plan := p.plan(_state({}), {"goal": true}, actions)
	assert_eq(plan.size(), 0, "三段链在 max_depth=1 时必须放弃，而不是硬凑")


func test_multi_key_goal() -> void:
	var p := GoapPlanner.new()
	var grab := _act("grab", {}, {"has_food": true})
	var gear := _act("gear", {}, {"armed": true})
	var plan := p.plan(_state({}), {"has_food": true, "armed": true}, [grab, gear])
	assert_eq(plan.size(), 2, "多键目标应规划出两条行动")
	var used := _defs(plan)
	assert_true(used.has(grab) and used.has(gear), "两条行动都应在计划里")


## 规划器不得改动传入的世界状态（它是"推演"，不是"执行"）。
func test_plan_does_not_mutate_state() -> void:
	var p := GoapPlanner.new()
	var ws := _state({"hp": 10})
	p.plan(ws, {"hp": 0}, [_act("hit", {}, {"hp": 0})])
	assert_eq(ws.get_value("hp"), 10, "推演不能写回真实世界状态")
