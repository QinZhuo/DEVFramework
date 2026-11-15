extends TestCase

## ECS 组件生命周期钩子(on_add/on_remove/on_destroy) + 变化检测。
## 钩子漏触发/多触发都不会报错, 只会让上层缓存与展示悄悄过期。

var _events: Array = []


func _on_add(entity: int) -> void:
	_events.append(["add", entity])


func _on_remove(entity: int) -> void:
	_events.append(["remove", entity])


func _on_destroy(entity: int) -> void:
	_events.append(["destroy", entity])


func test_lifecycle_hooks_and_dirty_flags() -> void:
	var w := ECSWorld.new(false)
	w.register_component(PTCompA)
	w.register_component(PTCompB)
	w.on_component_added(PTCompA, _on_add)
	w.on_component_removed(PTCompA, _on_remove)
	w.on_entity_destroyed(_on_destroy)

	# ---- 立即版 add/remove + 变化检测 ----
	var e1 := w.create_entity()
	w.add_component(e1, PTCompA)
	w.add_component(e1, PTCompB)
	assert_eq(_events.size(), 1, "只有 A(B 未挂钩子) 触发 add")
	assert_true(_events[0][0] == "add" and _events[0][1] == e1, "add 钩子应带实体 id")
	assert_false(w.is_component_dirty(PTCompA), "add 后的组件不该是脏的")

	_events.clear()
	w.set_field(e1, PTCompA, &"x", 5)
	assert_true(w.is_component_dirty(PTCompA), "set_field 应标脏")
	assert_true(w.dirty_components().has(&"PTCompA"), "脏组件清单应含 PTCompA")
	w.set_column(PTCompA, &"x", PackedInt32Array([7, 7]))
	assert_true(w.is_component_dirty(PTCompA), "set_column 应标脏")

	# get_column 只读, 不触发钩子
	_events.clear()
	var col: PackedInt32Array = w.get_column(PTCompA, &"x")
	assert_eq(col.size(), 1, "取列应返回 1 行")
	w.remove_component(e1, PTCompA)
	assert_true(_events.size() == 1 and _events[0][0] == "remove" and _events[0][1] == e1,
			"remove 钩子应带实体 id")

	# ---- destroy 触发 remove + on_destroy ----
	w.add_component(e1, PTCompA)
	_events.clear()
	w.destroy_entity(e1)
	assert_eq(_events.size(), 2, "销毁应先 remove 再 destroy")
	assert_true(_events[0][0] == "remove", "第一个事件应为 remove")
	assert_true(_events[1][0] == "destroy" and _events[1][1] == e1, "第二个事件应为 destroy")

	# ---- 命令缓冲版: cmd_add_component → flush 后触发 ----
	_events.clear()
	var h := w.cmd_create()
	w.cmd_add_component(h, PTCompA)
	w.cmd_flush()
	assert_true(_events.size() == 1 and _events[0][0] == "add", "命令缓冲 add 应在 flush 后触发")

	# ---- 命令缓冲版: cmd_destroy → flush 后触发 remove + destroy ----
	_events.clear()
	var e2 := w.create_entity()
	w.add_component(e2, PTCompA)
	_events.clear()
	w.cmd_destroy(e2)
	w.cmd_flush()
	assert_eq(_events.size(), 2, "命令缓冲销毁应触发 remove + destroy")
	assert_true(_events[0][0] == "remove" and _events[1][0] == "destroy", "事件顺序应为 remove → destroy")
