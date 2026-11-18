extends TestCase

## GOAP 的两个"真实成本"优化: **事件驱动重规划** + **计划缓存**。
##
## 依据(实测): 一次 12 条行动的链式搜索 ≈ 202µs; 而 2000 个 agent 的"计时记账"只要 0.05ms。
## 所以能省钱的不是存储形态, 是**规划次数**。


func _act(n: String, pre: Dictionary, eff: Dictionary, cost := 1.0) -> GoapActionDef:
	var d := GoapActionDef.new()
	d.name = n
	d.preconditions = pre
	d.effects = eff
	d.cost = cost
	return d


func _chain(n: int) -> Array:
	var out := []
	for i in n - 1:
		out.append(_act("a%d" % i, {"s%d" % i: true}, {"s%d" % (i + 1): true}))
	out.append(_act("fin", {"s%d" % (n - 1): true}, {"done": true}))
	return out


func _state(values: Dictionary) -> GoapWorldState:
	var ws := GoapWorldState.new()
	ws.reset(values)
	return ws


## 相同 (状态, 目标, 行动集) 第二次必须命中缓存, 且计划内容一致。
func test_cache_hit_and_equivalence() -> void:
	GoapPlanner.clear_plan_cache()
	var p := GoapPlanner.new()
	var acts := _chain(4)
	var ws := _state({"s0": true})
	var goal := {"done": true}

	var first := p.plan_cached(ws, goal, acts)
	var st1 := GoapPlanner.plan_cache_stats()
	assert_eq(int(st1["misses"]), 1, "第一次应未命中")
	assert_eq(first.size(), 4, "链长应为 4")

	var second := p.plan_cached(ws, goal, acts)
	var st2 := GoapPlanner.plan_cache_stats()
	assert_eq(int(st2["hits"]), 1, "第二次应命中缓存")
	assert_eq(second.size(), first.size(), "命中后的计划长度必须一致")
	for i in first.size():
		assert_true(second[i].def == first[i].def, "第 %d 步的行动定义应一致" % i)


## 缓存 key 用**内容指纹**: 另一个 agent(不同的 Planner 实例、不同的行动数组对象)
## 只要内容相同就必须命中 —— 否则"大量同构小兵"根本省不到。
func test_cache_is_shared_across_agents() -> void:
	GoapPlanner.clear_plan_cache()
	var acts_a := _chain(4)
	var acts_b := _chain(4)          # 另建一份同内容数组
	var p1 := GoapPlanner.new()
	var p2 := GoapPlanner.new()
	p1.plan_cached(_state({"s0": true}), {"done": true}, acts_a)
	var hit := p2.plan_cached(_state({"s0": true}), {"done": true}, acts_b)
	var st := GoapPlanner.plan_cache_stats()
	assert_eq(int(st["hits"]), 1, "不同 Agent 的等价输入应命中同一条缓存")
	assert_eq(hit.size(), 4, "命中后的计划仍应完整")


## 状态不同 → 不能命中(缓存必须对状态敏感, 否则会给出错误计划)。
func test_cache_key_sensitive_to_state() -> void:
	GoapPlanner.clear_plan_cache()
	var p := GoapPlanner.new()
	var acts := _chain(4)
	p.plan_cached(_state({"s0": true}), {"done": true}, acts)
	p.plan_cached(_state({"s1": true}), {"done": true}, acts)
	var st := GoapPlanner.plan_cache_stats()
	assert_eq(int(st["hits"]), 0, "状态不同不应命中")
	assert_eq(int(st["entries"]), 2, "应各存一条")


## 缓存必须显著快于搜索(这是它存在的全部理由)。
func test_cache_is_fast() -> void:
	GoapPlanner.clear_plan_cache()
	var p := GoapPlanner.new()
	# 链长 14：单次搜索的成本足够大，不会被调度抖动吃掉；缓存侧仍近似常数。
	var acts := _chain(14)
	var ws := _state({"s0": true})
	var goal := {"done": true}
	# 真实用法: 行动集签名预计算一次(GoapAgent 也是这么做的)
	var sig := GoapPlanner.actions_signature(acts)
	p.plan_cached(ws, goal, acts, 0, sig)   # 预热(写入缓存)

	var cached := PerfTool.bench(func() -> void: p.plan_cached(ws, goal, acts, 0, sig), 50, 15)
	var raw := PerfTool.bench(func() -> void: p.plan(ws, goal, acts), 20, 5)
	assert_true(raw.p50_ms > 0.05, "基准测不出来(raw=%.3fms)，不能拿噪声当结论" % raw.p50_ms)
	assert_true(cached.p50_ms < raw.p50_ms * 0.25,
			"命中缓存应至少快 4×: cached=%.3fms raw=%.3fms" % [cached.p50_ms, raw.p50_ms])


## 事件驱动: 没有状态变化时, tick 不应触发规划。
## 判据用 plan_found 信号计数(真正的行为, 不是内部标志)。
func test_event_driven_no_replan_without_dirty() -> void:
	var agent := GoapAgent.new()
	# ⚠ goals/actions 是 Array[GoapActionDef] 强类型, 不能直接赋无类型数组
	var g: Array[GoapGoalDef] = [_goal({"done": true})]
	var a: Array[GoapActionDef] = [_act("go", {}, {"done": true})]   # 一步可达, 避免前提不足导致空计划
	agent.goals = g
	agent.actions = a
	agent.auto_plan = false          # 手动 tick, 不开自动 _process
	agent.replan_interval = 0.0      # 关掉限流, 让"是否规划"只看 dirty
	var fired := [0]
	agent.plan_found.connect(func(_g, _p) -> void: fired[0] += 1)
	agent._ready()                    # TestCase 不是 Node, 手动跑 _ready 建 planner/world_state

	agent.tick(0.1)                   # 首次: _world_dirty 初始为 true
	assert_eq(fired[0], 1, "首次应规划一次")
	agent.tick(0.1)
	agent.tick(0.1)
	assert_eq(fired[0], 1, "世界状态没变就不该再规划")

	# 计划正在执行时, 标脏也不会打断(原有语义: 不中途换计划, 只置脏等回到 IDLE)
	agent.mark_dirty()
	agent.tick(0.1)
	assert_eq(fired[0], 1, "执行中不应被脏标记打断")
	agent.free()


func _goal(goal_state: Dictionary) -> GoapGoalDef:
	var g := GoapGoalDef.new()
	g.name = "test_goal"
	g.goal_state = goal_state
	return g
