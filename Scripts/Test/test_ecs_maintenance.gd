extends TestCase

## ECS 维护性契约: 批量命令缓冲、空块压缩、逐实体读写守卫。
##
## 这三条都不是"功能", 而是防止**性能被悄悄吃掉**的机制:
## 1) 逐条 cmd_* 在 2000 实体时要 4000 次跨语言调用, 比直接改结构还慢 → 会被绕开 → 绕开就会在遍历中改结构;
## 2) 空 archetype 块只增不减 → 聚合/遍历每帧空转;
## 3) 逐实体 get/set_field 每次约 2.8µs, 1000 个就是 2.8ms, 且不会报错。


## 批量入队与逐条等价: 占位句柄可解析、flush 后组件到位、批量销毁同样生效。
func test_cmd_bulk_enqueue() -> void:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)

	var handles := w.cmd_create_many(4)
	assert_eq(handles.size(), 4, "应返回 4 个占位句柄")
	assert_true(handles[0] < 0, "占位句柄必须是负数(与实体 id 区分)")
	assert_eq(int(w.native().call(&"pending_command_count")), 4, "4 条 create 已入队")

	w.cmd_add_many(handles, PTCompA)
	assert_eq(int(w.native().call(&"pending_command_count")), 8, "4 create + 4 add")
	w.cmd_flush()

	assert_eq(w.query_rows(PTCompA).size(), 4, "flush 后应有 4 行")
	for h in handles:
		var e: int = w.native().call(&"created_entity_at", -h - 1)
		assert_true(e >= 0 and w.is_alive(e), "占位句柄 %d 应解析到存活实体" % h)

	w.cmd_destroy_many(w.query_entities(PTCompA))
	assert_eq(int(w.native().call(&"pending_command_count")), 4, "4 条 destroy 已入队")
	w.cmd_flush()
	assert_eq(w.query_rows(PTCompA).size(), 0, "批量销毁后应为空")


## 批量 create 之后再用单条 cmd_create, 占位序号必须连续(两套入口共用一个序列)。
func test_cmd_bulk_then_single_keeps_sequence() -> void:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	var bulk := w.cmd_create_many(3)
	var single := w.cmd_create()
	assert_eq(single, -4, "单条 create 的占位应接在批量之后(-(3+1))")
	w.cmd_add_many(bulk, PTCompA)
	w.cmd_add_component(single, PTCompA)
	w.cmd_flush()
	assert_eq(w.query_rows(PTCompA).size(), 4, "4 个实体都应带组件")


## 空块压缩: 存活实体的数据/迁移不受影响, 匹配缓存与迁移图在压缩后仍可用。
func test_compact_archetypes_keeps_live_data() -> void:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	w.register_component(PTCompB)

	var keep := w.create_entity()
	w.add_component(keep, PTCompA)
	w.set_field(keep, PTCompA, &"x", 5)

	# 造一个"只含 B"的块, 再清空它 → 留下空块
	var tmp := w.create_entity()
	w.add_component(tmp, PTCompB)
	w.destroy_entity(tmp)

	var before: int = w.native().call(&"archetype_count")
	var removed: int = w.compact_archetypes()
	assert_true(removed >= 1, "应移除至少一个空块(实际 %d)" % removed)
	assert_eq(w.native().call(&"archetype_count"), before - removed, "块数应相应下降")

	var col: PackedInt32Array = w.get_column(PTCompA, &"x")
	assert_eq(col.size(), 1, "存活实体仍在")
	assert_eq(col[0], 5, "压缩不能动数据")

	# 压缩清掉了迁移图/匹配缓存: 之后的加删组件必须仍然正确
	w.add_component(keep, PTCompB)
	assert_eq(w.query_rows(PTCompB).size(), 1, "压缩后加组件应正确")
	w.remove_component(keep, PTCompB)
	assert_eq(w.query_rows(PTCompB).size(), 0, "压缩后删组件应正确")
	assert_eq(int(w.get_column(PTCompA, &"x")[0]), 5, "往返迁移后数据仍保留")

	# 删组件又把 AB 块清空了 → 这次压缩应只剩它; 再压一次才是真正的无操作
	assert_eq(w.compact_archetypes(), 1, "往返迁移留下的空块应被清掉")
	assert_eq(w.compact_archetypes(), 0, "无空块时应返回 0")


## 逐实体读写守卫: 只统计"系统上下文内"的访问(系统外的初始化/夹具不算误用)。
func test_entity_access_guard_counts_only_in_system() -> void:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	var e := w.create_entity()
	w.add_component(e, PTCompA)

	w.begin_frame_stats()
	w.get_field(e, PTCompA, &"x")
	w.set_field(e, PTCompA, &"x", 1)
	assert_eq(w._entity_calls, 0, "系统外的访问不应计数(否则初始化代码天天报警)")

	w.begin_system("ProbeSystem")
	w.get_field(e, PTCompA, &"x")
	w.set_field(e, PTCompA, &"x", 2)
	w.end_system()
	assert_eq(w._entity_calls, 2, "系统内的一次读一次写应各计一次")

	w.get_field(e, PTCompA, &"x")
	assert_eq(w._entity_calls, 2, "退出系统后不再计数")
	assert_eq(w.ENTITY_CALL_WARN, 256, "告警阈值(低于此值的零星单点访问不该报警)")
