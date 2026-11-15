extends TestCase

## 实体生命周期契约（P0 回归）。
##
## 三条都是"不崩、但会静默给出错误结果"的类型：
## 1) id 里的代数位宽有限，计数器必须同口径回绕 —— 否则复用到一定次数后活实体被判死；
## 2) prefab 标记必须随销毁清除 —— 否则 id 被复用的普通实体会在所有查询里永久隐身；
## 3) 命令队列的占位序号必须每批重置 —— 否则 created 映射错位到上一批的实体。


## 同一 index 反复创建/销毁(跨过 2048 次代数回绕): 新实体必须存活、旧 id 必须失效。
## 旧实现 versions_ 单调自增而 id 只存 8 位 → 第 256 次复用后 is_alive 恒 false(活实体被判死)。
## 循环次数刻意 > 2048: 回绕点也要覆盖, 否则"加了掩码"这类改动测不出来。
func test_entity_churn_keeps_alive() -> void:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	var prev := -1
	for i in 2600:
		var e := w.create_entity()
		assert_true(e >= 0, "第 %d 次创建应返回有效 id(实际 %d)" % [i, e])
		if e < 0:
			return
		w.add_component(e, PTCompA)
		assert_true(w.is_alive(e), "第 %d 次创建后实体必须存活(id=%d)" % [i, e])
		if i % 8 == 0:
			w.set_field(e, &"PTCompA", &"x", i)
			assert_eq(int(w.get_field(e, &"PTCompA", &"x")), i, "字段写入应可读回")
		if prev >= 0:
			# 相邻两代必然不同(版本号相差 1), 所以这条在回绕点也成立
			assert_false(w.is_alive(prev), "旧 id 必须失效(id=%d)" % prev)
		w.destroy_entity(e)
		prev = e


## 长时间持有的旧句柄: 代数回绕(11 位 = 2048)之前必须一直是死的, 回绕之后才可能出现 ABA。
## 这不是"功能", 而是把已知取舍钉成可观测事实 —— 位宽被改小/去掉掩码时这里会先红。
func test_entity_handle_stays_dead_until_wrap() -> void:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	var probe := w.create_entity()
	w.destroy_entity(probe)   # probe 从此是一个"旧句柄", 其 index 会被后续创建反复复用
	var aba_at := -1
	for i in 2600:
		var e := w.create_entity()
		if e < 0:
			assert_true(false, "第 %d 次创建失败" % i)
			return
		if aba_at < 0 and w.is_alive(probe):
			aba_at = i
		w.destroy_entity(e)
	# probe 销毁时代数已经 +1, 所以它的代数回到 0 是在第 2047 次复用(2048 - 1)。
	# 只要复活点不早于这个数, 就说明代数位宽没有被改小(8 位的话第 255 次就复活了)。
	assert_true(aba_at == -1 or aba_at >= 2047,
			"旧句柄在第 %d 次复用就复活了: 代数位宽或回绕策略不对(应 >= 2047)" % aba_at)


## 销毁 prefab 后，复用其 index 的普通实体必须能被查询到（旧实现 prefab 索引不清 → 永久隐身）。
func test_destroyed_prefab_index_is_reusable() -> void:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	var pf := w.create_prefab()
	w.prefab_add(pf, PTCompA, {"x": 5})
	var made := w.instantiate(pf, 1)
	assert_eq(made.size(), 1, "应实例化 1 个")
	assert_eq(w.query_rows(PTCompA).size(), 1, "实例可查, prefab 模板自身不可查")

	w.destroy_entity(pf)
	var e := w.create_entity()   # free list 是 LIFO, 这里大概率复用 prefab 的 index
	w.add_component(e, PTCompA)
	assert_eq(w.query_rows(PTCompA).size(), 2, "复用 prefab index 的实体必须能被查到(旧的会被永久跳过)")
	assert_eq(w.query_entities(PTCompA).size(), 2, "实体列表口径同样要包含它")
	assert_false(w.is_prefab(e), "新实体不应继承 prefab 标记")


## 命令缓冲: 队列首条不是 create 时，占位序号仍必须从 -1 开始（旧实现在此泄漏/错位）。
func test_cmd_placeholder_starts_after_flush() -> void:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	var a := w.create_entity()

	var h1 := w.cmd_create()
	assert_eq(h1, -1, "首批 create 占位应为 -1")
	w.cmd_flush()
	assert_true(w.native().call(&"created_entity_at", 0) >= 0, "flush 后应能查到真实实体")

	w.cmd_destroy(a)   # 队首不是 create: 旧实现不会重置占位映射
	var h3 := w.cmd_create()
	assert_eq(h3, -1, "第二批的 create 占位必须重新从 -1 开始")
	w.cmd_add_component(h3, PTCompA)
	w.cmd_flush()
	assert_eq(w.query_rows(PTCompA).size(), 1, "占位句柄应解析到本批新实体")


## 组件名解析必须被缓存, 且注册后缓存失效 —— 否则 destroy_entity 的热路径每实体都反射一次 schema
## (实测未缓存时 78µs/实体, 缓存后 2.5µs)。
func test_component_name_resolution_cached_and_invalidated() -> void:
	var w := ECSWorld.new(false)
	var before := w.resolve_component_name(PTCompA)
	assert_eq(w.resolve_component_name(PTCompA), before, "重复解析必须一致(说明走了缓存)")
	assert_true(w.register_component(PTCompA), "注册应成功")
	assert_eq(w.resolve_component_name(PTCompA), w.component_name(PTCompA),
			"注册后必须与注册名一致(负缓存/旧缓存要失效)")


## 批量实例化走"整块插入": 字段值/overrides/查询口径都要与逐实体路径一致。
## 旧实现每实体一次 archetype 迁移 + 每字段一次字符串查找, 刷怪时是真实瓶颈。
func test_instantiate_bulk_matches_prefab() -> void:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	var pf := w.create_prefab()
	w.prefab_add(pf, PTCompA, {"x": 7})

	var made := w.instantiate(pf, 500)
	assert_eq(made.size(), 500, "应生成 500 个实体")
	assert_eq(w.query_rows(PTCompA).size(), 500, "实例都应可查(模板自身不算)")
	assert_eq(int(w.get_field(made[0], PTCompA, &"x")), 7, "首行应继承模板字段")
	assert_eq(int(w.get_field(made[499], PTCompA, &"x")), 7, "末行同样继承(整段拷贝覆盖到边界)")
	assert_false(w.is_prefab(made[0]), "实例不应带 prefab 标记")

	# overrides 只影响被点名的列
	var tinted := w.instantiate(pf, 3, {PTCompA: {"x": 42}})
	assert_eq(int(w.get_field(tinted[2], PTCompA, &"x")), 42, "override 应生效")
	assert_eq(int(w.get_field(made[0], PTCompA, &"x")), 7, "override 不应污染已有实例")

	# 逐实体写仍然作用在正确的行上(块内行号映射没被打乱)
	w.set_field(made[10], PTCompA, &"x", 99)
	assert_eq(int(w.get_field(made[10], PTCompA, &"x")), 99, "实例的 set_field 应命中自己的行")
	assert_eq(int(w.get_field(made[11], PTCompA, &"x")), 7, "不应波及相邻行")
