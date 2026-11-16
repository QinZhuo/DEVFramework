extends TestCase

## ECS 计时器(组件 + 系统)的行为与规模探针。
##
## 这个模块的语义容易错在三处, 用例就盯着这三处:
##   ① 到期**当帧**就要处理(不能留负值到下一帧, 否则事件晚一帧、且无限循环计时器会漏跳);
##   ② 一次性 → 销毁计时器实体; 重复 → 重置 left 且 repeat_count 递减; -1 → 永不销毁;
##   ③ 到期处理会**销毁实体**(swap-remove 会打乱行号), 所以必须先把行号映射成实体 id 再动手。


func _world() -> ECSWorld:
	var w := ECSWorld.new(false)
	w.register_component(TimerComponent)
	return w


## 一次性计时器: 未到期不触发, 到期后实体被销毁且事件只发一次。
func test_expire_once() -> void:
	var w := _world()
	var host := w.create_entity()
	var t := TimerSystem.add(w, host, 1.0, {"tag": 7})
	assert_true(w.is_alive(t), "计时器实体应存在")
	assert_approx(TimerSystem.remaining(w, t), 1.0, "初始剩余应等于时长")

	assert_eq(TimerSystem.tick(w, 0.5), 0, "0.5s 时不该到期")
	assert_approx(TimerSystem.remaining(w, t), 0.5, "剩余应减到 0.5")

	var got: Array = []
	w.on_event(&"timer_expired", func(p) -> void: got.append(p))
	assert_eq(TimerSystem.tick(w, 0.6), 1, "1.1s 时应到期 1 个")
	assert_false(w.is_alive(t), "一次性计时器到期后应销毁")

	w.tick(0.0)   # 派发本帧事件
	assert_eq(got.size(), 1, "到期事件应恰好 1 次")
	assert_eq(int(got[0].get("tag")), 7, "事件应带出 tag")
	assert_eq(int(got[0].get("target")), host, "事件应带出宿主")


## 重复计时器: 到期后重置并递减次数, 次数用完才销毁。
func test_repeat_count() -> void:
	var w := _world()
	var host := w.create_entity()
	var t := TimerSystem.add(w, host, 0.5, {"repeat_count": 1})
	assert_eq(int(w.get_field(t, TimerComponent, &"repeat_mode")), TimerComponent.RepeatMode.REPEAT,
			"只给 repeat_count>0 时应推断为 REPEAT")
	assert_eq(TimerSystem.tick(w, 0.6), 1, "第一次到期")
	assert_true(w.is_alive(t), "还有剩余次数, 不应销毁")
	assert_approx(TimerSystem.remaining(w, t), 0.5, "应重置为完整时长")
	assert_eq(int(w.get_field(t, TimerComponent, &"repeat_count")), 0, "次数应递减")
	assert_eq(TimerSystem.tick(w, 0.6), 1, "第二次到期")
	assert_false(w.is_alive(t), "次数用完后销毁")


## 无限循环(-1): 多次到期仍然存活。
func test_repeat_infinite() -> void:
	var w := _world()
	var host := w.create_entity()
	var t := TimerSystem.add(w, host, 0.1, {"repeat_count": -1})
	assert_eq(int(w.get_field(t, TimerComponent, &"repeat_mode")), TimerComponent.RepeatMode.FOREVER,
			"repeat_count<0 应推断为 FOREVER")
	var n := 0
	for i in 3:
		n += TimerSystem.tick(w, 0.2)
	assert_eq(n, 3, "应到期 3 次")
	assert_true(w.is_alive(t), "无限循环不应销毁")
	assert_eq(int(w.get_field(t, TimerComponent, &"repeat_count")), -1, "次数不该变化")


## 枚举字段在 ECS 里就是 int 列: 写入、存档、读档都要保住值。
func test_enum_field_roundtrip() -> void:
	var w := _world()
	var host := w.create_entity()
	var t := TimerSystem.add(w, host, 5.0, {"mode": TimerComponent.RepeatMode.FOREVER, "tag": 3})
	assert_eq(int(w.get_field(t, TimerComponent, &"repeat_mode")), TimerComponent.RepeatMode.FOREVER,
			"枚举值应原样写入")
	var snap: Dictionary = w.serialize()
	var w2 := ECSWorld.new(false)
	w2.register_component(TimerComponent)
	w2.deserialize(snap)
	var ents := w2.query_entities(TimerComponent)
	assert_eq(ents.size(), 1, "读档后应有 1 个计时器")
	assert_eq(int(w2.get_field(ents[0], TimerComponent, &"repeat_mode")), TimerComponent.RepeatMode.FOREVER,
			"存档往返应保住枚举值")
	assert_eq(int(w2.get_field(ents[0], TimerComponent, &"tag")), 3, "tag 也应保住")


## 取消: 销毁后不再产生到期事件。
func test_cancel() -> void:
	var w := _world()
	var host := w.create_entity()
	var t := TimerSystem.add(w, host, 0.2)
	assert_true(TimerSystem.cancel(w, t), "取消应成功")
	assert_false(TimerSystem.cancel(w, t), "重复取消应返回 false")
	assert_eq(TimerSystem.tick(w, 1.0), 0, "已取消的计时器不该到期")
	assert_eq(TimerSystem.remaining(w, t), -1.0, "非计时器剩余应为 -1")


## 一个宿主可以挂多个计时器; target 过滤只取自己的。
func test_multiple_per_host_and_target_filter() -> void:
	var w := _world()
	var a := w.create_entity()
	var b := w.create_entity()
	TimerSystem.add(w, a, 1.0, {"tag": 1})
	TimerSystem.add(w, a, 2.0, {"tag": 2})
	TimerSystem.add(w, b, 3.0, {"tag": 3})
	assert_eq(TimerSystem.timers_of(w, a).size(), 2, "a 应有 2 个计时器")
	assert_eq(TimerSystem.timers_of(w, b).size(), 1, "b 应有 1 个计时器")
	# 推进 1.1s → 只有 a 的 1s 那个到期
	assert_eq(TimerSystem.tick(w, 1.1), 1, "只应到期 1 个")
	assert_eq(TimerSystem.timers_of(w, a).size(), 1, "a 还剩 1 个")


## 多 archetype: 到期处理是"整列读 + 按行号写回", 依赖 query_entities 与 columns_of 的**聚合行序一致**。
## 这里把计时器分成两组(一组多挂一个组件 → 落到不同 archetype), 验证到期/销毁不会串行。
func test_multi_archetype_alignment() -> void:
	var w := ECSWorld.new(false)
	w.register_component(TimerComponent)
	w.register_component(PTCompA)
	var host := w.create_entity()
	var a_ids := PackedInt32Array()   # 只有 TimerComponent
	var b_ids := PackedInt32Array()   # TimerComponent + PTCompA
	for i in 60:
		var t := TimerSystem.add(w, host, 0.5, {"tag": i})
		if i % 2 == 0:
			a_ids.append(t)
		else:
			w.add_component(t, PTCompA)
			b_ids.append(t)
	assert_eq(w.count(TimerComponent), 60, "两组都应挂在同一条组件上")
	assert_eq(TimerSystem.tick(w, 1.0), 60, "跨 archetype 也应全部到期")
	assert_eq(w.count(TimerComponent), 0, "一次性计时器应全部销毁")
	# 另一组: 无限循环 + 多 archetype → 重置后仍存活且 left 被重新装满
	for i in 40:
		var t := TimerSystem.add(w, host, 0.5, {"mode": TimerComponent.RepeatMode.FOREVER, "tag": i})
		if i % 2 == 1:
			w.add_component(t, PTCompA)
	assert_eq(TimerSystem.tick(w, 1.0), 40, "循环计时器应全部到期一次")
	assert_eq(w.count(TimerComponent), 40, "循环计时器不应销毁")
	var lefts: PackedFloat32Array = w.get_column(TimerComponent, &"left")
	for v in lefts:
		assert_approx(v, 0.5, "重置后 left 应回到 duration")



## 空闲推进的性能闸门(没有到期项, 但每帧都要付的钱)。
##
## 旧实现(逐对象 GameTimer.advance)已迁出框架, 所以这里只钉**绝对阈值**:
##   实测 1000 个 ≈ 0.045ms、2000 个 ≈ 0.062ms(次线性);
##   超过 1ms 说明退化成了"逐实体跨语言"路径(每条 1.4µs 那种)。
func test_idle_tick_within_budget() -> void:
	const N := 1000
	var w := _world()
	var host := w.create_entity()
	for i in N:
		TimerSystem.add(w, host, 100.0, {"mode": TimerComponent.RepeatMode.FOREVER, "tag": i})
	TimerSystem.tick(w, 0.016)   # 预热(建列/缓存)
	var t := PerfTool.bench(func() -> void: TimerSystem.tick(w, 0.016), 10, 3)
	assert_true(t.p50_ms < 1.0,
			"空闲推进 %d 个超预算: %.3fms (阈值 1.0)" % [N, t.p50_ms])


## 规模: 2000 个计时器同时到期, 一次 tick 处理完且不退化(逐对象实现约 0.65ms/帧)。
func test_bulk_2000() -> void:
	var w := ECSWorld.new(false)
	w.register_component(TimerComponent)
	var host := w.create_entity()
	var timers := PackedInt32Array()
	timers.resize(2000)
	for i in 2000:
		timers[i] = TimerSystem.add(w, host, 0.5, {"tag": i})

	# 稳态(无到期)应远快于逐对象轮询
	var t0 := Time.get_ticks_usec()
	var n := 0
	for i in 10:
		n += TimerSystem.tick(w, 0.001)
	var idle_us := float(Time.get_ticks_usec() - t0) / 10.0
	assert_eq(n, 0, "0.01s 内不该有到期")

	# 一次跨过到期点
	var start := Time.get_ticks_usec()
	var expired := TimerSystem.tick(w, 1.0)
	var bulk_us := float(Time.get_ticks_usec() - start)
	assert_eq(expired, 2000, "2000 个应全部到期")
	assert_eq(w.count(TimerComponent), 0, "一次性计时器应全部销毁")
	assert_true(bulk_us < 50000.0, "2000 个到期处理超时: %.1fms" % (bulk_us / 1000.0))
	# 空闲推进的开销也钉一下(宽松阈值, 只抓数量级回退)
	assert_true(idle_us < 5000.0, "2000 个计时器空闲推进超时: %.1fµs" % idle_us)
